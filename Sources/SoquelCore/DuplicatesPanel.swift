import AppKit

/// Reviewing duplicates before anything is deleted.
///
/// The scan is the easy half. Every row starts unticked, one copy in each group
/// is marked as the keeper, and what happens is a move to the Trash that Undo
/// can take back.
final class DuplicatesPanelController: NSWindowController {
    static let shared: DuplicatesPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Duplicates"
        window.setFrameAutosaveName("SoquelDuplicates")
        let controller = DuplicatesPanelController(window: window)
        controller.build()
        return controller
    }()

    private struct Row {
        let group: Duplicates.Group
        let url: URL
        let isKeeper: Bool
        var ticked: Bool
    }

    private var outline: NSOutlineView!
    private var footer: NSTextField!
    private var trashButton: NSButton!
    private var report = Duplicates.Report()
    private var keepers: [String: URL] = [:]
    private var ticked: Set<URL> = []
    private var scan: DispatchWorkItem?
    private var roots: [URL] = []

    var onChanged: (() -> Void)?

    private func build() {
        outline = NSOutlineView()
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: "")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        footer.translatesAutoresizingMaskIntoConstraints = false

        let tickAll = NSButton(title: "Tick All But Keepers", target: self, action: #selector(tickAllButKeepers))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTicks))
        trashButton = NSButton(title: "Move to Trash", target: self, action: #selector(trashTicked))
        trashButton.keyEquivalent = "\r"
        trashButton.isEnabled = false
        for button in [tickAll, clear, trashButton!] {
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        let content = window!.contentView!
        [scroll, footer, tickAll, clear, trashButton].forEach { content.addSubview($0!) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: tickAll.leadingAnchor, constant: -10),

            tickAll.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            tickAll.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            trashButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    func show(roots: [URL], over parent: NSWindow?) {
        self.roots = roots
        window?.title = roots.count == 1
            ? "Duplicates in \(roots[0].lastPathComponent)"
            : "Duplicates in \(roots.count) folders"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        rescan()
    }

    private func rescan() {
        scan?.cancel()
        report = Duplicates.Report()
        keepers = [:]
        ticked = []
        outline.reloadData()
        footer.stringValue = "Scanning…"
        trashButton.isEnabled = false

        let targets = roots
        let includeHidden = Prefs.showHiddenFiles
        let work = DispatchWorkItem { [weak self] in
            let found = Duplicates.scan(roots: targets, includeHidden: includeHidden) {
                self?.scan?.isCancelled ?? true
            }
            DispatchQueue.main.async {
                guard let self, self.scan?.isCancelled == false else { return }
                self.report = found
                for group in found.groups {
                    self.keepers[group.hash] = Duplicates.suggestedKeep(group)
                }
                self.outline.reloadData()
                for group in found.groups { self.outline.expandItem(group.hash) }
                self.updateFooter()
            }
        }
        scan = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func updateFooter() {
        let count = ticked.count
        footer.stringValue = count == 0
            ? report.summary
            : "\(report.summary) · \(count) ticked"
        trashButton.isEnabled = count > 0
    }

    @objc private func tickAllButKeepers() {
        ticked = []
        for group in report.groups {
            for url in Duplicates.trashable(group, keeping: keepers[group.hash]) {
                ticked.insert(url)
            }
        }
        outline.reloadData()
        updateFooter()
    }

    @objc private func clearTicks() {
        ticked = []
        outline.reloadData()
        updateFooter()
    }

    @objc private func toggleTick(_ sender: NSButton) {
        guard let url = sender.cell?.representedObject as? URL else { return }
        if sender.state == .on { ticked.insert(url) } else { ticked.remove(url) }
        updateFooter()
    }

    @objc private func trashTicked() {
        let urls = report.groups.flatMap(\.urls).filter { ticked.contains($0) }
        guard !urls.isEmpty else { return }

        // Every group must keep something. Ticking a whole group is how a
        // duplicate finder destroys the only copy.
        let emptied = report.groups.filter { group in
            !group.urls.contains { !ticked.contains($0) }
        }
        guard emptied.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Some groups have nothing left"
            alert.informativeText = emptied.count == 1
                ? "One group has every copy ticked. Untick one to keep."
                : "\(emptied.count) groups have every copy ticked. Untick one in each to keep."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Move 1 file to the Trash?" : "Move \(urls.count) items to the Trash?"
        alert.informativeText = "They go to the Trash and ⌘Z brings them back."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        OperationEngine.shared.trash(urls) { [weak self] result in
            guard let self else { return }
            UndoStack.shared.pushTrash(result.trashedPairs)
            self.onChanged?()
            self.rescan()
        }
    }

    override func close() {
        scan?.cancel()
        super.close()
    }
}

extension DuplicatesPanelController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func group(for hash: String) -> Duplicates.Group? {
        report.groups.first { $0.hash == hash }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let hash = item as? String else { return report.groups.count }
        return group(for: hash)?.urls.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let hash = item as? String else { return report.groups[index].hash }
        return group(for: hash)?.urls[index] ?? URL(fileURLWithPath: "/")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()

        if let hash = item as? String, let group = group(for: hash) {
            let size = ByteCountFormatter.string(fromByteCount: group.reclaimable, countStyle: .file)
            let what = group.isFolder ? "identical folders" : "identical files"
            let field = NSTextField(labelWithString:
                "\(group.urls.count) \(what) · \(size) reclaimable")
            field.font = Theme.rowName
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        guard let url = item as? URL,
              let hash = outlineView.parent(forItem: item) as? String,
              let group = group(for: hash)
        else { return nil }

        let isKeeper = keepers[group.hash] == url
        let box = NSButton(checkboxWithTitle: url.path, target: self, action: #selector(toggleTick(_:)))
        box.cell?.representedObject = url
        box.state = ticked.contains(url) ? .on : .off
        box.font = Theme.rowSecondary
        box.lineBreakMode = .byTruncatingMiddle
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)

        var trailing = cell.trailingAnchor
        if isKeeper {
            let tag = NSTextField(labelWithString: "keep")
            tag.font = Theme.status
            tag.textColor = .secondaryLabelColor
            tag.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tag)
            NSLayoutConstraint.activate([
                tag.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tag.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            trailing = tag.leadingAnchor
        }

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            box.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -6),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
