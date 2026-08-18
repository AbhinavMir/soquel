import AppKit

/// Recent files and recent actions, side by side in one window.
///
/// Two views over the same list. "Files" is one row per file, newest first —
/// the answer to "where did I just save that". "Actions" is everything in
/// order, which is the answer to "what did I just do to it".
final class RecentsPanelController: NSWindowController {
    static let shared: RecentsPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Recents"
        window.setFrameAutosaveName("SoquelRecents")
        window.isReleasedWhenClosed = false
        let controller = RecentsPanelController(window: window)
        controller.build()
        if !window.setFrameUsingName("SoquelRecents") { window.center() }
        return controller
    }()

    private var table: NSTableView!
    private var modeControl: NSSegmentedControl!
    private var status: NSTextField!
    private var rows: [Recents.Entry] = []
    private weak var host: MainWindowController?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func build() {
        modeControl = NSSegmentedControl(labels: ["Files", "Actions"], trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(revealClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reveal = NSButton(title: "Show in Soquel", target: self, action: #selector(revealClicked))
        reveal.keyEquivalent = "\r"
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearClicked))

        let buttons = NSStackView(views: [clear, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(modeControl)
        root.addSubview(scroll)
        root.addSubview(status)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            modeControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            scroll.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    func show(for controller: MainWindowController) {
        _ = window
        host = controller
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    @objc private func modeChanged() { reload() }

    private func reload() {
        rows = modeControl.selectedSegment == 0 ? Recents.files() : Recents.all
        table.reloadData()
        status.stringValue = rows.isEmpty
            ? "Nothing yet — this fills in as you work"
            : "\(rows.count) \(modeControl.selectedSegment == 0 ? "files" : "actions")"
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private var selected: Recents.Entry? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    @objc private func revealClicked() {
        guard let entry = selected, let host else { return }
        // A trashed or moved file is not where it was; saying so beats
        // navigating to a folder and selecting nothing.
        guard FileManager.default.fileExists(atPath: entry.path) else {
            status.stringValue = "\(entry.name) is no longer there"
            NSSound.beep()
            return
        }
        host.reveal(entry.url)
        host.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func clearClicked() {
        let alert = NSAlert()
        alert.messageText = "Clear the recents list?"
        alert.informativeText = "The files themselves are untouched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Recents.clear()
        reload()
    }
}

extension RecentsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]

        let id = NSUserInterfaceItemIdentifier("recentRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let fresh = NSTableCellView()
            fresh.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            let when = NSTextField(labelWithString: "")
            when.translatesAutoresizingMaskIntoConstraints = false
            when.font = Theme.rowNumeric
            when.textColor = .tertiaryLabelColor
            when.alignment = .right
            when.identifier = NSUserInterfaceItemIdentifier("when")
            fresh.addSubview(icon)
            fresh.addSubview(field)
            fresh.addSubview(when)
            fresh.imageView = icon
            fresh.textField = field
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: fresh.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                field.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                when.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 8),
                when.trailingAnchor.constraint(equalTo: fresh.trailingAnchor, constant: -6),
                when.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
            ])
            return fresh
        }()

        let gone = !FileManager.default.fileExists(atPath: entry.path)
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.path)
        cell.imageView?.alphaValue = gone ? 0.4 : 1
        cell.textField?.stringValue = modeControl.selectedSegment == 0 ? entry.name : entry.summary
        cell.textField?.textColor = gone ? .tertiaryLabelColor : .labelColor
        cell.toolTip = entry.path
        let when = cell.subviews.first {
            ($0 as? NSTextField)?.identifier?.rawValue == "when"
        } as? NSTextField
        when?.stringValue = Self.dateFormatter.string(from: entry.at)
        return cell
    }
}
