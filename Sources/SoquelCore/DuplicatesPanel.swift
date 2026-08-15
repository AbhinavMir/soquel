import AppKit

/// Reviewing duplicates before anything is deleted.
///
/// The scan is the easy half. Every row starts unticked, one copy in each group
/// is marked as the keeper, and what happens is a move to the Trash that Undo
/// can take back. On a volume without a Trash the panel warns and deletes
/// outright instead, the same way the file list does.
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
        window.delegate = controller
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
        // The closures must watch the work item they belong to. Reading
        // `self.scan` looked equivalent, but rescan() points it at the newest
        // item and cancel() does not stop one already running, so a superseded
        // scan polled the new item's flag, kept hashing, and could deliver the
        // old folder's groups under the new title. The reference is weak so
        // the item does not retain itself; the queue holds it while it runs.
        weak var weakWork: DispatchWorkItem?
        let work = DispatchWorkItem { [weak self] in
            guard let work = weakWork else { return }
            let found = Duplicates.scan(roots: targets, includeHidden: includeHidden) {
                work.isCancelled
            }
            DispatchQueue.main.async {
                guard let self, self.scan === work, !work.isCancelled else { return }
                self.report = found
                for group in found.groups {
                    self.keepers[group.hash] = Duplicates.suggestedKeep(group)
                }
                self.outline.reloadData()
                for group in found.groups { self.outline.expandItem(group.hash) }
                self.updateFooter()
            }
        }
        weakWork = work
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

        // On a network share there is no Trash: trashItem throws instead of
        // falling back, so promising that ⌘Z brings things back would be
        // false and nothing would be deleted at all. Warn the way the file
        // list does, and send those items through the permanent delete the
        // user just agreed to. The ordinary local case keeps its ordinary
        // confirmation.
        if let warning = TrashPolicy.warning(for: urls) {
            let alert = NSAlert()
            alert.messageText = warning.title
            alert.informativeText = warning.body
            let readOnly = urls.contains {
                if case .readOnly = TrashPolicy.outcome(for: $0) { return true }
                return false
            }
            if readOnly {
                alert.runModal()
                return
            }
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else {
            let alert = NSAlert()
            alert.messageText = urls.count == 1 ? "Move 1 file to the Trash?" : "Move \(urls.count) items to the Trash?"
            alert.informativeText = "They go to the Trash and ⌘Z brings them back."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let permanent = urls.filter { !TrashPolicy.outcome(for: $0).isRecoverable }
        let recoverable = urls.filter { TrashPolicy.outcome(for: $0).isRecoverable }

        let finish: (OperationResult) -> Void = { [weak self] result in
            guard let self else { return }
            UndoStack.shared.pushTrash(result.trashedPairs)
            // A failed trash looks exactly like a successful one from here —
            // the rescan lists the same rows again — so the failures have to
            // be said out loud, as the file list does for the same operation.
            if !result.failures.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                let noun = "item\(result.failures.count == 1 ? "" : "s")"
                alert.messageText = permanent.isEmpty
                    ? "Could not move \(result.failures.count) \(noun) to the Trash"
                    : "Could not delete \(result.failures.count) \(noun)"
                alert.informativeText = result.failures.prefix(8)
                    .map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
                    .joined(separator: "\n")
                alert.runModal()
            }
            self.onChanged?()
            self.rescan()
        }

        if permanent.isEmpty {
            OperationEngine.shared.trash(urls, completion: finish)
        } else if recoverable.isEmpty {
            OperationEngine.shared.deletePermanently(permanent, completion: finish)
        } else {
            OperationEngine.shared.deletePermanently(permanent) { deleted in
                OperationEngine.shared.trash(recoverable) { trashed in
                    var merged = trashed
                    merged.succeeded.append(contentsOf: deleted.succeeded)
                    merged.failures.append(contentsOf: deleted.failures)
                    finish(merged)
                }
            }
        }
    }
}

extension DuplicatesPanelController: NSWindowDelegate {
    /// Closing mid-scan stops the hashing rather than leaving it churning
    /// through a tree nobody is watching. The titlebar close button never
    /// calls the controller's `close()`, so this must live on the window
    /// delegate to see that path at all.
    func windowWillClose(_ notification: Notification) {
        scan?.cancel()
        scan = nil
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
