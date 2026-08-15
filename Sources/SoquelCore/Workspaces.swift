import AppKit

/// A saved arrangement of panes and tabs, reopened by name.
///
/// Session restore already brings back whatever was open; this is the step
/// beyond that the research records as a stated purchase reason — named
/// layouts per project, switched deliberately rather than inherited from
/// whatever happened to be open last.
struct Workspace: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// One entry per pane; each is that pane's tab paths, in order.
    var panes: [[String]]
    /// Which tab was in front, per pane.
    var activeTabs: [Int]
    /// The orientation of the outermost split. Kept for workspaces saved
    /// before `layout` existed, and as the shape to fall back to.
    var isVerticalSplit: Bool
    /// How the panes are arranged, as indices into `panes`.
    ///
    /// Absent in anything saved before nested splits, which reopens as a
    /// single row or column — the old format could not express a tree.
    var layout: LayoutNode?

    /// A saved arrangement. Panes are indices rather than identifiers because
    /// identifiers are made fresh each run.
    indirect enum LayoutNode: Codable, Equatable {
        case pane(Int)
        case split(vertical: Bool, children: [LayoutNode])

        /// Every pane index, in reading order.
        var indices: [Int] {
            switch self {
            case .pane(let index): return [index]
            case .split(_, let children): return children.flatMap(\.indices)
            }
        }

        /// Drops panes whose folders have gone, collapsing any split left
        /// holding one child. Returns nil when nothing survives.
        func keeping(_ surviving: Set<Int>) -> LayoutNode? {
            switch self {
            case .pane(let index):
                return surviving.contains(index) ? self : nil
            case .split(let vertical, let children):
                let remaining = children.compactMap { $0.keeping(surviving) }
                switch remaining.count {
                case 0: return nil
                case 1: return remaining[0]
                default: return .split(vertical: vertical, children: remaining)
                }
            }
        }

        /// Renumbers after panes have been dropped, so the indices line up
        /// with the shortened list.
        func renumbered(_ mapping: [Int: Int]) -> LayoutNode? {
            switch self {
            case .pane(let index):
                return mapping[index].map { .pane($0) }
            case .split(let vertical, let children):
                let remaining = children.compactMap { $0.renumbered(mapping) }
                switch remaining.count {
                case 0: return nil
                case 1: return remaining[0]
                default: return .split(vertical: vertical, children: remaining)
                }
            }
        }
    }

    /// Only the folders that still exist, so a workspace survives a moved
    /// project rather than failing to open at all.
    func survivingPanes() -> [[String]] {
        survivingPanesWithIndices().map(\.tabs)
    }

    /// The surviving panes, each with the position it had when saved, so the
    /// arrangement can be rebuilt around the gaps.
    func survivingPanesWithIndices() -> [(index: Int, tabs: [String])] {
        panes.enumerated().compactMap { index, tabs in
            let present = tabs.filter { FileManager.default.fileExists(atPath: $0) }
            return present.isEmpty ? nil : (index, present)
        }
    }

    /// The arrangement to rebuild, with dropped panes removed and the rest
    /// renumbered. Nil when the workspace predates nested splits or nothing of
    /// its arrangement survives, in which case a flat row is the answer.
    func survivingLayout(
        _ precomputed: [(index: Int, tabs: [String])]? = nil
    ) -> LayoutNode? {
        guard let layout else { return nil }
        // Callers that already scanned pass their result in, so the layout is
        // built from the same snapshot the panes were.
        let surviving = precomputed ?? survivingPanesWithIndices()
        let mapping = Dictionary(
            uniqueKeysWithValues: surviving.enumerated().map { ($1.index, $0) }
        )
        return layout.keeping(Set(mapping.keys))?.renumbered(mapping)
    }

    var isUsable: Bool { !survivingPanes().isEmpty }

    /// "3 panes · Website" for the menu subtitle.
    var summary: String {
        let count = panes.count
        return "\(count) pane\(count == 1 ? "" : "s")"
    }
}

/// Loads and saves workspaces as readable JSON, as the spec asks.
enum WorkspaceStore {
    static var fileURL: URL {
        ThemeConfig.directoryURL.appendingPathComponent("workspaces.json")
    }

    static var all: [Workspace] = load() {
        didSet {
            guard all != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .soquelWorkspacesChanged, object: nil)
        }
    }

    /// One broken entry must not empty the store: `all` starts from load(),
    /// and the next mutation saves `all` back, so an all-or-nothing decode
    /// turned one bad hand edit into every workspace gone.
    private struct Lenient: Decodable {
        let workspace: Workspace?
        init(from decoder: Decoder) {
            workspace = try? Workspace(from: decoder)
        }
    }

    private static func load() -> [Workspace] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Lenient].self, from: data) else {
            // Not JSON at all. Put the file aside so the next save cannot
            // overwrite what the user wrote by hand.
            let backup = fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.error(.app, "workspaces.json did not parse; kept as \(backup.lastPathComponent)")
            return []
        }
        let survivors = decoded.compactMap(\.workspace)
        let dropped = decoded.count - survivors.count
        if dropped > 0 {
            Log.error(.app, "\(dropped) workspace entr\(dropped == 1 ? "y" : "ies") did not parse and were dropped")
        }
        return survivors
    }

    private static func save() {
        try? FileManager.default.createDirectory(
            at: ThemeConfig.directoryURL, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.app, "could not write workspaces.json: \(error.localizedDescription)")
        }
    }

    static func add(_ workspace: Workspace) {
        // Saving under a name that already exists replaces it, which is what
        // "save workspace" means when you have rearranged the panes.
        var current = all
        current.removeAll { $0.name.caseInsensitiveCompare(workspace.name) == .orderedSame }
        current.append(workspace)
        all = current
    }

    static func remove(id: UUID) {
        all.removeAll { $0.id == id }
    }

    static func rename(id: UUID, to name: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var current = all
        current[index].name = name
        all = current
    }

    static func workspace(named name: String) -> Workspace? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension Notification.Name {
    static let soquelWorkspacesChanged = Notification.Name("app.soquel.workspacesChanged")
}

/// The body of Go > Manage Workspaces…: every saved workspace in a table,
/// with a button to rename the selected one in place and one to delete it.
///
/// The alert that hosts this used to list the names as plain text with a
/// Done button, so the only way to be rid of a workspace, or to fix its name,
/// was to open workspaces.json and edit it by hand. The store already had
/// `remove` and `rename`; nothing on screen called them.
///
/// The outer size is a frame, not constraints, because NSAlert takes an
/// accessory view's frame as the space to give it.
final class WorkspaceManagerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var table: NSTableView!
    private var status: NSTextField!
    private var renameButton: NSButton!
    private var deleteButton: NSButton!
    private var workspaces: [Workspace] = WorkspaceStore.all

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 194))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.style = .inset
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Name"
        name.width = 270
        let panes = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("panes"))
        panes.title = "Panes"
        panes.width = 110
        table.addTableColumn(name)
        table.addTableColumn(panes)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        renameButton = NSButton(title: "Rename", target: self, action: #selector(renameSelected))
        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        let buttons = NSStackView(views: [renameButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "Select a workspace, then Rename or Delete.")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(buttons)
        addSubview(status)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 160),

            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),

            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = workspaces.indices.contains(table.selectedRow)
        renameButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    @objc private func renameSelected() {
        let row = table.selectedRow
        guard workspaces.indices.contains(row) else { return }
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard workspaces.indices.contains(row) else { return }
        let workspace = workspaces[row]
        WorkspaceStore.remove(id: workspace.id)
        workspaces = WorkspaceStore.all
        table.reloadData()
        status.stringValue = "Deleted “\(workspace.name)”."
        updateButtons()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { workspaces.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard workspaces.indices.contains(row), let tableColumn else { return nil }
        let workspace = workspaces[row]
        let isName = tableColumn.identifier.rawValue == "name"

        let field = NSTextField(labelWithString: isName ? workspace.name : workspace.summary)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if isName {
            // Editable in place; the delegate commits the new name when
            // editing ends.
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
        } else {
            field.textColor = .secondaryLabelColor
        }

        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - Renaming

    /// Return while editing commits the name and stays in the dialog. Left to
    /// the field editor, Return would also press the alert's default button
    /// and close the whole thing mid-rename.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard workspaces.indices.contains(row) else { return }
        let workspace = workspaces[row]
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)

        // An empty name is not a rename; the old one comes back.
        guard !name.isEmpty, name != workspace.name else {
            field.stringValue = workspace.name
            return
        }
        // Names are how workspaces are opened, so two cannot share one.
        if let other = WorkspaceStore.workspace(named: name), other.id != workspace.id {
            field.stringValue = workspace.name
            status.stringValue = "There is already a workspace called “\(name)”."
            NSSound.beep()
            return
        }

        WorkspaceStore.rename(id: workspace.id, to: name)
        // The row already shows the new name; a reload here would tear down
        // the field whose editing is still being wound up.
        workspaces[row].name = name
        status.stringValue = "Renamed to “\(name)”."
    }
}
