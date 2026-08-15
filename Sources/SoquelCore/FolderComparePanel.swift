import AppKit

/// Side-by-side folder comparison, and copying the differences.
///
/// Rows live in an NSTableView so only the visible ones are built. A first
/// sync of a large tree makes every file a difference, and building a
/// constraint-laden view per entry on the main thread beachballed for minutes
/// once the counts reached the tens of thousands.
final class FolderComparePanelController: NSWindowController {
    static let shared: FolderComparePanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare Folders"
        window.setFrameAutosaveName("SoquelCompare")
        let controller = FolderComparePanelController(window: window)
        window.delegate = controller
        controller.build()
        return controller
    }()

    private var leftRoot: URL?
    private var rightRoot: URL?
    private var entries: [FolderCompare.Entry] = []
    /// The entries the table is showing, after the differences-only filter.
    /// Stored, not computed: the table indexes into it once per visible row.
    private var visible: [FolderCompare.Entry] = []
    /// Relative paths the user has ticked for copying.
    private var chosen: Set<String> = []

    private var header: NSTextField!
    private var footer: NSTextField!
    private var table: NSTableView!
    private var spinner: NSProgressIndicator!
    private var precisionControl: NSSegmentedControl!
    private var hiddenCheckbox: NSButton!
    private var differencesOnly: NSButton!
    private var copyRightButton: NSButton!
    private var copyLeftButton: NSButton!

    /// Set while a comparison is running, and read by the walk to stop early.
    private var cancelled = false
    private var isComparing = false
    /// Bumped per scan; a completion whose number no longer matches is from a
    /// superseded scan and is discarded rather than shown.
    private var scanGeneration = 0

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Building

    private func build() {
        header = NSTextField(labelWithString: "No folders chosen")
        header.font = Theme.path
        header.lineBreakMode = .byTruncatingMiddle
        header.translatesAutoresizingMaskIntoConstraints = false

        precisionControl = NSSegmentedControl(
            labels: ["Size and date", "Checksum"], trackingMode: .selectOne,
            target: self, action: #selector(optionsChanged)
        )
        precisionControl.selectedSegment = 0
        precisionControl.toolTip = "Checksum reads every byte of both sides."
        precisionControl.translatesAutoresizingMaskIntoConstraints = false

        hiddenCheckbox = NSButton(
            checkboxWithTitle: "Hidden files", target: self, action: #selector(optionsChanged)
        )
        hiddenCheckbox.state = .on

        differencesOnly = NSButton(
            checkboxWithTitle: "Differences only", target: self, action: #selector(filterChanged)
        )
        differencesOnly.state = .on

        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescan))

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let options = NSStackView(views: [precisionControl, hiddenCheckbox, differencesOnly, rescan, spinner])
        options.orientation = .horizontal
        options.spacing = 10
        options.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.style = .fullWidth
        table.backgroundColor = .clear
        // The checkbox is the only interaction a row has; a selection would
        // suggest the copy buttons act on it, and they act on the ticks.
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: "")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let selectAll = NSButton(title: "Select All Differences", target: self, action: #selector(selectAllDifferences))
        let selectNone = NSButton(title: "Select None", target: self, action: #selector(selectNone))
        copyLeftButton = NSButton(title: "◀ Copy to Left", target: self, action: #selector(copyToLeft))
        copyRightButton = NSButton(title: "Copy to Right ▶", target: self, action: #selector(copyToRight))
        copyRightButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [selectAll, selectNone, copyLeftButton, copyRightButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(options)
        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            options.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            options.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    // MARK: - Running

    func show(left: URL, right: URL) {
        leftRoot = left
        rightRoot = right
        header.stringValue = "\(left.path)    ⟷    \(right.path)"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        rescan(nil)
    }

    @objc private func optionsChanged(_ sender: Any?) {
        rescan(nil)
    }

    @objc private func filterChanged(_ sender: Any?) {
        refreshRows()
    }

    @objc private func rescan(_ sender: Any?) {
        guard let leftRoot, let rightRoot else { return }
        // A scan already running is superseded, not respected: show() may
        // just have pointed the panel at different folders, and the old
        // results would land under the new header — and a copy planned from
        // them would write into the wrong folders. Bumping the generation
        // makes the old scan cancel itself and its completion discard.
        scanGeneration += 1
        let generation = scanGeneration
        isComparing = true
        cancelled = false
        chosen.removeAll()
        entries = []
        refreshRows()
        footer.stringValue = "Comparing…"
        spinner.startAnimation(nil)
        setActionsEnabled(false)

        let precision: FolderCompare.Precision = precisionControl.selectedSegment == 1 ? .checksum : .quick
        let includeHidden = hiddenCheckbox.state == .on

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FolderCompare.compare(
                left: leftRoot, right: rightRoot,
                precision: precision, includeHidden: includeHidden,
                isCancelled: { self.map { $0.cancelled || $0.scanGeneration != generation } ?? true }
            )
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation, !self.cancelled else { return }
                self.isComparing = false
                self.spinner.stopAnimation(nil)
                self.entries = result
                // Differences start ticked: the point of opening this is to act
                // on them, and untangling a fully unticked list is busywork.
                // Type conflicts cannot be ticked at all: one side is a folder,
                // syncing over it would destroy a tree, and plan() refuses
                // them — so an enabled checkbox would be a promise the copy
                // silently breaks.
                self.chosen = Set(result
                    .filter { $0.status.isDifference && $0.status != .typeConflict }
                    .map(\.relativePath))
                self.refreshRows()
                self.setActionsEnabled(true)
            }
        }
    }

    private func setActionsEnabled(_ enabled: Bool) {
        copyLeftButton.isEnabled = enabled
        copyRightButton.isEnabled = enabled
    }

    // MARK: - Rows

    private func refreshRows() {
        visible = differencesOnly.state == .on ? entries.filter { $0.status.isDifference } : entries
        table.reloadData()
        updateFooter()
    }

    private func updateFooter() {
        guard !isComparing else { return }
        let summary = FolderCompare.summarize(entries)
        if entries.isEmpty {
            footer.stringValue = "Nothing to compare"
        } else if summary.differenceCount == 0 {
            footer.stringValue = "The two folders match — \(summary.identical) items"
        } else {
            footer.stringValue = "\(summary.onlyLeft) left only · \(summary.onlyRight) right only · "
                + "\(summary.differs) differ · \(summary.identical) same · \(chosen.count) selected"
        }
    }

    private func statusColor(_ status: FolderCompare.Status) -> NSColor {
        switch status {
        case .identical: return .tertiaryLabelColor
        case .typeConflict: return Theme.danger
        default: return Theme.accent
        }
    }

    private func describe(_ side: FolderCompare.Side?) -> String {
        guard let side else { return "—" }
        if side.isDirectory { return "folder" }
        return Self.byteFormatter.string(fromByteCount: side.size)
            + "  " + Self.dateFormatter.string(from: side.modified)
    }

    // MARK: - Selection

    @objc private func toggleRow(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if sender.state == .on { chosen.insert(path) } else { chosen.remove(path) }
        updateFooter()
    }

    @objc private func selectAllDifferences(_ sender: Any?) {
        // Type conflicts stay out, exactly as the rescan completion leaves
        // them: plan() refuses them and their checkbox is disabled, so a
        // tick set here could never be cleared by hand, and the footer
        // would count a copy that will never happen.
        chosen = Set(entries
            .filter { $0.status.isDifference && $0.status != .typeConflict }
            .map(\.relativePath))
        refreshRows()
    }

    @objc private func selectNone(_ sender: Any?) {
        chosen.removeAll()
        refreshRows()
    }

    // MARK: - Copying

    @objc private func copyToRight(_ sender: Any?) { copy(direction: .leftToRight) }
    @objc private func copyToLeft(_ sender: Any?) { copy(direction: .rightToLeft) }

    private func copy(direction: FolderCompare.Direction) {
        guard let leftRoot, let rightRoot, let window else { return }
        let selected = entries.filter { chosen.contains($0.relativePath) }
        let plans = FolderCompare.plan(selected, direction: direction, left: leftRoot, right: rightRoot)
        guard !plans.isEmpty else {
            footer.stringValue = "Nothing selected to copy \(direction == .leftToRight ? "right" : "left")"
            return
        }

        // Overwrites are confirmed once for the batch, naming the count, rather
        // than per file — a per-file prompt on a large sync is unusable.
        let overwrites = plans.filter(\.overwrites).count
        let alert = NSAlert()
        alert.messageText = "\(direction.label): \(plans.count) file\(plans.count == 1 ? "" : "s")"
        alert.informativeText = overwrites == 0
            ? "No existing files will be replaced."
            : "\(overwrites) existing file\(overwrites == 1 ? " will be" : "s will be") replaced."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        if overwrites > 0 { alert.alertStyle = .warning }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.setActionsEnabled(false)
            self.footer.stringValue = "Copying \(plans.count)…"
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                // The first error aborts the batch and the throw discards the
                // return value, so the completed count arrives through the
                // progress callback instead.
                var copied = 0
                do { try FolderCompare.apply(plans, progress: { copied = $0 }) } catch { failure = error }
                DispatchQueue.main.async {
                    self.setActionsEnabled(true)
                    // Rescanning is the honest confirmation that it worked. It
                    // also rewrites the footer straight away, so a failure has
                    // to go in an alert — a footer line would be erased before
                    // it was ever drawn.
                    self.rescan(nil)
                    if let failure, let window = self.window {
                        let stopped = NSAlert()
                        stopped.messageText =
                            "Copied \(copied) of \(plans.count), then stopped"
                        stopped.informativeText = failure.localizedDescription
                        stopped.alertStyle = .warning
                        stopped.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

}

extension FolderComparePanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let entry = visible[row]
        let container = NSView()

        let tick = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
        tick.state = chosen.contains(entry.relativePath) ? .on : .off
        tick.identifier = NSUserInterfaceItemIdentifier(entry.relativePath)
        // A type conflict can never be copied — plan() refuses to let a file
        // replace a folder — so an enabled checkbox would promise a copy that
        // silently never happens.
        tick.isEnabled = entry.status.isDifference && entry.status != .typeConflict
        if entry.status == .typeConflict {
            tick.toolTip = "A file cannot replace a folder. Resolve this one by hand."
        }
        tick.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: entry.status.label)
        status.font = Theme.sectionLabel
        status.textColor = statusColor(entry.status)
        status.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: entry.relativePath)
        path.font = Theme.rowName
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = entry.relativePath
        path.translatesAutoresizingMaskIntoConstraints = false

        let left = NSTextField(labelWithString: describe(entry.left))
        left.font = Theme.rowNumeric
        left.textColor = .secondaryLabelColor
        left.alignment = .right
        left.translatesAutoresizingMaskIntoConstraints = false

        let right = NSTextField(labelWithString: describe(entry.right))
        right.font = Theme.rowNumeric
        right.textColor = .secondaryLabelColor
        right.alignment = .right
        right.translatesAutoresizingMaskIntoConstraints = false

        for view in [tick, status, path, left, right] as [NSView] { container.addSubview(view) }

        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tick.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            status.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: 6),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 86),

            path.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 8),
            path.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            path.trailingAnchor.constraint(equalTo: left.leadingAnchor, constant: -10),

            left.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            left.widthAnchor.constraint(equalToConstant: 150),
            left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -14),

            right.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            right.widthAnchor.constraint(equalToConstant: 150),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        return container
    }
}

extension FolderComparePanelController: NSWindowDelegate {
    /// Closing the panel mid-scan stops the walk rather than leaving it to
    /// finish reading two trees nobody is looking at.
    func windowWillClose(_ notification: Notification) {
        cancelled = true
    }
}
