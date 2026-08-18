import AppKit

/// Shows a unified diff: two files compared, or a patch somebody sent.
///
/// A window rather than a sheet, so it can be left open beside the folder
/// while the files it describes are worked on — which is how a diff is
/// actually read.
final class DiffPanelController: NSWindowController {
    static let shared: DiffPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Compare"
        window.setFrameAutosaveName("SoquelDiff")
        // No NSWindowController owns a raw window's release; without this the
        // close would over-release it, as it did in the SFTP browser.
        window.isReleasedWhenClosed = false
        let controller = DiffPanelController(window: window)
        controller.build()
        if !window.setFrameUsingName("SoquelDiff") { window.center() }
        return controller
    }()

    private var table: NSTableView!
    private var header: NSTextField!
    private var summary: NSTextField!
    private var spinner: NSProgressIndicator!
    private var lines: [Diff.Line] = []
    /// Bumped per comparison, so a slow diff that lands after another was
    /// asked for cannot draw over it.
    private var generation = 0

    private static let numberWidth: CGFloat = 44

    private func build() {
        header = NSTextField(labelWithString: "")
        header.font = Theme.path
        header.lineBreakMode = .byTruncatingMiddle
        header.translatesAutoresizingMaskIntoConstraints = false

        summary = NSTextField(labelWithString: "")
        summary.font = Theme.status
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 16
        table.intercellSpacing = .zero
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        for id in ["old", "new", "text"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = id == "text" ? 700 : Self.numberWidth
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy Diff", target: self, action: #selector(copyDiff))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(spinner)
        root.addSubview(scroll)
        root.addSubview(summary)
        root.addSubview(copyButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),

            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),

            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            summary.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    // MARK: - Showing

    /// Compares two files.
    func show(_ left: URL, _ right: URL) {
        present(title: "\(left.lastPathComponent) ⟷ \(right.lastPathComponent)")
        generation += 1
        let token = generation
        lines = []
        table.reloadData()
        spinner.startAnimation(nil)
        summary.stringValue = "Comparing…"

        Diff.compare(left, right) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.spinner.stopAnimation(nil)
            self.apply(result)
        }
    }

    /// Shows a patch file as it stands.
    func show(patch url: URL) {
        present(title: url.lastPathComponent)
        generation += 1
        apply(Diff.read(patch: url))
    }

    /// Shows a diff that has already been produced, for the git side.
    func show(unified text: String, title: String) {
        present(title: title)
        generation += 1
        let parsed = Diff.parse(unified: text)
        apply(Diff.Result(lines: parsed, note: parsed.isEmpty ? "No differences" : nil))
    }

    private func present(title: String) {
        _ = window
        header.stringValue = title
        window?.title = "Compare — \(title)"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func apply(_ result: Diff.Result) {
        lines = result.lines
        table.reloadData()
        if let note = result.note {
            summary.stringValue = note
        } else {
            summary.stringValue = "\(result.added) added, \(result.removed) removed"
        }
    }

    @objc private func copyDiff() {
        let text = lines.map { line -> String in
            switch line.kind {
            case .added: return "+" + line.text
            case .removed: return "-" + line.text
            case .context: return " " + line.text
            case .hunk, .header: return line.text
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        summary.stringValue = "Copied the diff"
    }
}

extension DiffPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = DiffRowView()
        view.kind = lines.indices.contains(row) ? lines[row].kind : .context
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, lines.indices.contains(row) else { return nil }
        let line = lines[row]

        let id = NSUserInterfaceItemIdentifier("diffcell." + tableColumn.identifier.rawValue)
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.font = Theme.rowNumeric
            field.lineBreakMode = .byClipping
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch tableColumn.identifier.rawValue {
        case "old":
            cell.textField?.stringValue = line.oldNumber.map(String.init) ?? ""
            cell.textField?.alignment = .right
            cell.textField?.textColor = .tertiaryLabelColor
        case "new":
            cell.textField?.stringValue = line.newNumber.map(String.init) ?? ""
            cell.textField?.alignment = .right
            cell.textField?.textColor = .tertiaryLabelColor
        default:
            let marker: String
            switch line.kind {
            case .added: marker = "+"
            case .removed: marker = "−"
            default: marker = " "
            }
            cell.textField?.stringValue = marker + line.text
            cell.textField?.alignment = .left
            cell.textField?.textColor = line.kind == .hunk || line.kind == .header
                ? .secondaryLabelColor : .labelColor
        }
        return cell
    }
}

/// Paints the band behind a diff line. Colour carries the meaning here, so it
/// is drawn rather than left to a selection style that says nothing.
final class DiffRowView: NSTableRowView {
    var kind: Diff.Line.Kind = .context

    override func draw(_ dirtyRect: NSRect) {
        let colour: NSColor?
        switch kind {
        case .added: colour = NSColor.systemGreen.withAlphaComponent(0.16)
        case .removed: colour = NSColor.systemRed.withAlphaComponent(0.16)
        case .hunk: colour = NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        case .header, .context: colour = nil
        }
        guard let colour else { return }
        colour.setFill()
        bounds.fill()
    }
}
