import AppKit

struct PaletteCommand {
    let title: String
    /// Rendered form of the shortcut currently bound, e.g. `⇧⌘D`.
    let shortcut: String
    let run: (MainWindowController) -> Void
}

/// Fuzzy subsequence match. Returns nil when `needle` is not a subsequence of
/// `haystack`; lower scores rank better.
func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
    if needle.isEmpty { return 0 }
    let n = Array(needle.lowercased())
    let h = Array(haystack.lowercased())
    var ni = 0
    var score = 0
    var lastMatch = -1
    for (hi, ch) in h.enumerated() {
        guard ni < n.count else { break }
        if ch == n[ni] {
            if lastMatch >= 0 { score += hi - lastMatch - 1 }
            else { score += hi }
            lastMatch = hi
            ni += 1
        }
    }
    return ni == n.count ? score : nil
}

final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = CommandPalette()

    private var panel: NSPanel?
    private var field: NSTextField!
    private var table: NSTableView!
    private weak var owner: MainWindowController?

    private var all: [PaletteCommand] = []
    private var matches: [PaletteCommand] = []

    // MARK: - Command list

    /// Built from the same registry the menus use, so the shortcut shown beside
    /// a command is the one that is actually bound right now — including any
    /// remapping the user has made.
    private func buildCommands() -> [PaletteCommand] {
        CommandRegistry.all
            .filter(\.inPalette)
            .map { command in
                PaletteCommand(
                    title: command.title,
                    shortcut: command.shortcut?.display ?? "",
                    run: { controller in
                        let item = NSMenuItem()
                        item.representedObject = command.representedObject
                        item.tag = Int(command.representedObject ?? "") ?? 0
                        _ = controller.perform(command.selector, with: item)
                    }
                )
            }
    }

    // MARK: - Presentation

    func present(for controller: MainWindowController) {
        guard let host = controller.window else { return }
        // ⌘K while the palette is open would otherwise strand an unreachable
        // sheet on top of the first one.
        guard panel == nil else { return }
        owner = controller
        all = buildCommands()
        matches = all

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true

        field = NSTextField()
        field.placeholderString = "Run a command"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(runSelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        column.width = 480
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        self.panel = panel

        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        host.beginSheet(panel) { [weak self] _ in
            self?.panel = nil
            self?.owner = nil
        }
        panel.makeFirstResponder(field)
    }

    private func dismiss(then action: (() -> Void)? = nil) {
        guard let panel, let host = panel.sheetParent else { return }
        host.endSheet(panel)
        action?()
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard matches.indices.contains(row), let controller = owner else { dismiss(); return }
        let command = matches[row]
        dismiss { controller.runCommand(command) }
    }

    // MARK: - Filtering

    func controlTextDidChange(_ obj: Notification) {
        let needle = field.stringValue
        if needle.isEmpty {
            matches = all
        } else {
            matches = all
                .compactMap { cmd -> (PaletteCommand, Int)? in
                    fuzzyScore(needle, cmd.title).map { (cmd, $0) }
                }
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
        }
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let next = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let command = matches[row]
        let id = NSUserInterfaceItemIdentifier("cmdcell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13)
            title.translatesAutoresizingMaskIntoConstraints = false
            let shortcut = NSTextField(labelWithString: "")
            shortcut.font = .systemFont(ofSize: 11)
            shortcut.textColor = .secondaryLabelColor
            shortcut.alignment = .right
            shortcut.identifier = NSUserInterfaceItemIdentifier("shortcut")
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(title)
            cell.addSubview(shortcut)
            cell.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = command.title
        for sub in cell.subviews {
            if let field = sub as? NSTextField, field.identifier?.rawValue == "shortcut" {
                field.stringValue = command.shortcut
            }
        }
        return cell
    }
}
