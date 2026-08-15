import AppKit

/// One row in the sidebar outline.
final class SidebarNode {
    enum Kind {
        /// A user-defined group header.
        case userGroup(SidebarGroup)
        /// A fixed header, for sections derived from the system.
        case systemGroup(String)
        /// A pinned location the user can rename, re-icon, move, or remove.
        case pinned(SidebarItem)
        /// A mounted volume; not editable.
        case volume(URL, String)
        /// A folder in the browsable tree. Children load when it is expanded.
        case treeFolder(URL)
        /// A file in the browsable tree. A leaf: selecting it shows it in the
        /// pane rather than navigating into it.
        case treeFile(URL)
        /// Stands in for the files a folder is not showing. Selecting it swaps
        /// itself for the rest of them.
        case treeMore(parent: URL, hidden: [URL])
        /// A saved search. Selecting it re-runs the query rather than showing
        /// a remembered list of results.
        case savedSearch(SavedSearch)
    }

    let kind: Kind
    var children: [SidebarNode]
    /// Tree nodes start unloaded and fill in on first expansion.
    var childrenLoaded = false

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    var isGroup: Bool {
        switch kind {
        case .userGroup, .systemGroup: return true
        case .pinned, .volume, .treeFolder, .treeFile, .treeMore, .savedSearch: return false
        }
    }

    /// A tree folder is expandable before its children are known, so the
    /// disclosure triangle appears without a blocking scan.
    var isExpandable: Bool {
        if case .treeFolder = kind { return true }
        return isGroup
    }

    var url: URL? {
        switch kind {
        case .pinned(let item): return item.url
        case .volume(let url, _): return url
        case .treeFolder(let url): return url
        case .treeFile(let url): return url
        case .userGroup, .systemGroup, .savedSearch, .treeMore: return nil
        }
    }

    var title: String {
        switch kind {
        case .userGroup(let group): return group.title
        case .systemGroup(let title): return title
        case .pinned(let item): return item.title
        case .volume(_, let name): return name
        case .savedSearch(let search): return search.name
        case .treeFolder(let url), .treeFile(let url):
            let name = url.lastPathComponent
            return name.isEmpty ? url.path : name
        case .treeMore(_, let hidden):
            return hidden.count == 1 ? "1 more file" : "\(hidden.count) more files"
        }
    }

    var itemID: UUID? {
        if case .pinned(let item) = kind { return item.id }
        return nil
    }

    var groupID: UUID? {
        if case .userGroup(let group) = kind { return group.id }
        return nil
    }
}

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelect url: URL)
    /// Opens the folder holding `url` and selects it there. A file in the tree
    /// is somewhere to be shown, not somewhere to go.
    func sidebar(_ sidebar: SidebarViewController, revealFile url: URL)
    func sidebar(_ sidebar: SidebarViewController, openInNewTab url: URL)
    func sidebar(_ sidebar: SidebarViewController, run search: SavedSearch)
}

/// The sidebar's outline. Return and keypad Enter act on the selected row.
/// NSOutlineView ignores them, and they do not change the selection, so
/// without this a row whose work is held back from arrow-key traversal could
/// never be run from the keyboard at all.
private final class SidebarOutline: NSOutlineView {
    var onActivate: (() -> Void)?
    /// Called for a plain click that landed on the row that was already
    /// selected. Such a click changes no selection, so AppKit posts no
    /// selectionDidChange and the delegate never hears about it — yet for a
    /// row the selection gate holds back it is the whole request: arrow onto
    /// a saved search, then click it to run it.
    var onReclickSelectedRow: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        if key == UInt32(NSCarriageReturnCharacter) || key == UInt32(NSEnterCharacter) {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }

    /// NSOutlineView tracks the whole click inside mouseDown, so once super
    /// returns the click is settled and the selection is final. Only then can
    /// "the click landed on the row that was already selected, and it is
    /// still the selected row" be read off. Modified clicks are selection
    /// edits or the context menu, not a request to act on the row.
    override func mouseDown(with event: NSEvent) {
        let selectedBefore = selectedRow
        super.mouseDown(with: event)
        guard event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
              clickedRow >= 0, clickedRow == selectedBefore, selectedRow == selectedBefore
        else { return }
        onReclickSelectedRow?()
    }
}

final class SidebarViewController: NSViewController {
    weak var delegate: SidebarDelegate?

    private var outline: NSOutlineView!
    private var roots: [SidebarNode] = []
    private var observers: [NSObjectProtocol] = []
    /// The folder the tree is working its way down to, held while the levels
    /// load one at a time.
    fileprivate var pendingReveal: URL?
    /// Set while reveal() moves the selection itself. AppKit posts
    /// selectionDidChange for a programmatic selection exactly as it does for a
    /// click, and reveal() runs because the pane has already moved, so the row
    /// it highlights must not be handed back to the delegate as a fresh choice.
    private var isRevealingSelection = false
    /// True while the tree is being put back the way it was left. Expanding a
    /// folder during that would record it as a fresh choice by the user.
    fileprivate var isRestoringTree = false
    /// The folders still to be reopened, shallowest first. Emptied as the
    /// levels arrive.
    private var pendingRestore: [String] = Prefs.expandedTreeFolders
    /// How many tree listings are still being read. A restore pass must not
    /// conclude that a folder it cannot find is gone while any of these could
    /// still deliver the level that folder lives in.
    private var treeLoadsInFlight = 0
    /// Set while a row the user clicked is navigating the pane. The pane
    /// reports back and the tree follows it, and that follow must not take the
    /// highlight off the row that was clicked.
    private var navigationOrigin: SidebarNode.Kind?
    /// The same thing, carried for the length of a reveal walk.
    ///
    /// A walk down to a folder the tree has not opened yet loads one level per
    /// background read, so reveal() re-enters itself several runloop turns
    /// later. navigationOrigin is gone by then; this is not.
    private var revealOrigin: SidebarNode.Kind?

    /// Internal drag type for reordering pinned items.
    private static let itemDragType = NSPasteboard.PasteboardType("app.soquel.sidebarItem")

    override func loadView() {
        let sidebarOutline = SidebarOutline()
        sidebarOutline.onActivate = { [weak self] in self?.activateSelectedRow() }
        sidebarOutline.onReclickSelectedRow = { [weak self] in self?.activateSelectedRow() }
        outline = sidebarOutline
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.registerForDraggedTypes([.fileURL, Self.itemDragType])
        outline.setDraggingSourceOperationMask([.move], forLocal: true)
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 180
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        view = scroll
        applyTheme()
        rebuild()

        for name in [Notification.Name.soquelSidebarChanged, .soquelSavedSearchesChanged] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.rebuild()
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The sidebar is a big flat surface, so it carries the theme's chrome
    /// colour rather than staying whatever the system would paint it.
    func applyTheme() {
        guard let scroll = view as? NSScrollView else { return }
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.chrome
        outline?.backgroundColor = Theme.chrome
        outline?.enclosingScrollView?.drawsBackground = true
    }

    func rebuild() {
        var built: [SidebarNode] = []

        for group in SidebarStore.layout.groups {
            let children = group.items.map { SidebarNode(.pinned($0)) }
            built.append(SidebarNode(.userGroup(group), children: children))
        }

        let fm = FileManager.default
        var volumes: [SidebarNode] = []
        if let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                              options: [.skipHiddenVolumes]) {
            for volume in mounted {
                let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                    ?? volume.lastPathComponent
                volumes.append(SidebarNode(.volume(volume, name)))
            }
        }
        if !volumes.isEmpty {
            built.append(SidebarNode(.systemGroup("Locations"), children: volumes))
        }

        // iCloud, Google Drive and the rest. Ordinary folders that were always
        // reachable by typing the path; they were just never listed. Drawn as
        // volumes because that is what they are to anyone using them, and it
        // picks up the vendor's own icon off disk.
        let clouds = CloudDrives.all()
        if !clouds.isEmpty {
            built.append(SidebarNode(
                .systemGroup("Cloud"),
                children: clouds.map { SidebarNode(.volume($0.url, $0.name)) }
            ))
        }

        let searches = SavedSearchStore.all
        if !searches.isEmpty {
            built.append(SidebarNode(
                .systemGroup("Searches"), children: searches.map { SidebarNode(.savedSearch($0)) }
            ))
        }

        if Prefs.showFolderTree {
            let treeRoots = FolderTree.roots.map { SidebarNode(.treeFolder($0)) }
            built.append(SidebarNode(.systemGroup("Folders"), children: treeRoots))
        }

        roots = built
        outline.reloadData()
        for root in roots {
            if case .userGroup(let group) = root.kind, group.isCollapsed { continue }
            outline.expandItem(root)
        }
        // Put the tree back the way it was left. The first pass opens the top
        // level; each background load carries it one level deeper. The reload
        // built all-new nodes and dropped every expansion the outline held, so
        // the list of folders to reopen is re-read from the remembered paths;
        // whatever an earlier restore had already worked through is open no
        // longer.
        pendingRestore = Prefs.expandedTreeFolders
        restoreExpandedFolders()
    }

    // MARK: - Pinning

    /// Pins a folder, into a named group when one is given.
    func pin(_ url: URL, toGroup groupID: UUID? = nil) {
        var layout = SidebarStore.layout
        layout.addItem(SidebarItem(path: url.path), toGroup: groupID)
        SidebarStore.layout = layout
    }

    private func selectedNode() -> SidebarNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? SidebarNode
    }

    // MARK: - Context menu actions

    @objc private func renameItem() {
        guard let node = selectedNode(), let id = node.itemID,
              let item = SidebarStore.layout.item(id: id) else { return }
        guard let name = prompt(title: "Rename in Sidebar",
                                message: "This changes the label here only; the folder keeps its name.",
                                initial: item.title)
        else { return }
        var layout = SidebarStore.layout
        layout.updateItem(id: id) { $0.displayName = name.isEmpty ? nil : name }
        SidebarStore.layout = layout
    }

    @objc private func changeIcon() {
        guard let node = selectedNode(), let id = node.itemID else { return }
        guard let choice = IconPicker.run(current: SidebarStore.layout.item(id: id)?.icon) else { return }
        var layout = SidebarStore.layout
        layout.updateItem(id: id) { $0.icon = choice.isEmpty ? nil : choice }
        SidebarStore.layout = layout
    }

    @objc private func removeItem() {
        guard let node = selectedNode(), let id = node.itemID else { return }
        var layout = SidebarStore.layout
        layout.removeItem(id: id)
        SidebarStore.layout = layout
    }

    @objc private func newGroup() {
        guard let title = prompt(title: "New Group", message: "Name for the new sidebar section.",
                                 initial: "Group")
        else { return }
        var layout = SidebarStore.layout
        _ = layout.addGroup(title: title)
        SidebarStore.layout = layout
    }

    @objc private func renameGroup() {
        guard let node = selectedNode(), let id = node.groupID else { return }
        guard let title = prompt(title: "Rename Group", message: "", initial: node.title) else { return }
        var layout = SidebarStore.layout
        layout.renameGroup(id: id, to: title)
        SidebarStore.layout = layout
    }

    /// Removing a group takes its pinned rows with it, so it asks first.
    @objc private func removeGroup() {
        guard let node = selectedNode(), let id = node.groupID,
              let group = SidebarStore.layout.group(id: id) else { return }

        if !group.items.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Remove “\(group.title)” and its \(group.items.count) shortcut\(group.items.count == 1 ? "" : "s")?"
            alert.informativeText = "The folders themselves are not touched."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var layout = SidebarStore.layout
        layout.removeGroup(id: id)
        SidebarStore.layout = layout
    }

    @objc private func moveToGroup(_ sender: NSMenuItem) {
        guard let node = selectedNode(), let id = node.itemID,
              let target = sender.representedObject as? String,
              let groupID = UUID(uuidString: target)
        else { return }
        var layout = SidebarStore.layout
        let count = layout.group(id: groupID)?.items.count ?? 0
        layout.move(itemID: id, toGroup: groupID, at: count)
        SidebarStore.layout = layout
    }

    @objc private func openInNewTab() {
        guard let url = selectedNode()?.url else { return }
        delegate?.sidebar(self, openInNewTab: url)
    }

    @objc private func revealInFinder() {
        guard let url = selectedNode()?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func resetSidebar() {
        let alert = NSAlert()
        alert.messageText = "Reset the sidebar to its default groups?"
        alert.informativeText = "Your pinned shortcuts are removed. The folders themselves are not touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SidebarStore.reset()
    }

    private func prompt(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Menu

extension SidebarViewController {
    // MARK: - Saved searches

    private var selectedSavedSearch: SavedSearch? {
        guard let node = selectedNode(), case .savedSearch(let search) = node.kind else { return nil }
        return search
    }

    @objc func runSavedSearch() {
        guard let search = selectedSavedSearch else { return }
        delegate?.sidebar(self, run: search)
    }

    @objc func renameSavedSearch() {
        guard let search = selectedSavedSearch else { return }
        guard let name = prompt(
            title: "Rename Search", message: "A new name for this saved search.", initial: search.name
        ) else { return }
        SavedSearchStore.rename(id: search.id, to: name)
        rebuild()
    }

    @objc func removeSavedSearch() {
        guard let search = selectedSavedSearch else { return }
        SavedSearchStore.remove(id: search.id)
        rebuild()
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = selectedNode()

        if let node, case .savedSearch(let search) = node.kind {
            add(menu, "Run Search", #selector(runSavedSearch))
            menu.addItem(.separator())
            add(menu, "Rename Search…", #selector(renameSavedSearch))
            add(menu, "Remove Search", #selector(removeSavedSearch))
            if search.rootIsMissing {
                let note = NSMenuItem(
                    title: "Saved folder is gone — runs in the current folder", action: nil, keyEquivalent: ""
                )
                note.isEnabled = false
                menu.addItem(.separator())
                menu.addItem(note)
            }
            return
        }

        if let node, node.itemID != nil {
            add(menu, "Open in New Tab", #selector(openInNewTab))
            add(menu, "Reveal in Finder", #selector(revealInFinder))
            menu.addItem(.separator())
            add(menu, "Rename…", #selector(renameItem))
            add(menu, "Change Icon…", #selector(changeIcon))

            let groups = SidebarStore.layout.groups
            if groups.count > 1 {
                let moveItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for group in groups {
                    let entry = NSMenuItem(title: group.title, action: #selector(moveToGroup(_:)), keyEquivalent: "")
                    entry.representedObject = group.id.uuidString
                    entry.target = self
                    entry.state = group.items.contains { $0.id == node.itemID } ? .on : .off
                    submenu.addItem(entry)
                }
                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }
            add(menu, "Remove from Sidebar", #selector(removeItem))
            menu.addItem(.separator())
        } else if let node, node.groupID != nil {
            add(menu, "Rename Group…", #selector(renameGroup))
            add(menu, "Remove Group…", #selector(removeGroup))
            menu.addItem(.separator())
        }

        add(menu, "New Group…", #selector(newGroup))
        add(menu, "Reset Sidebar…", #selector(resetSidebar))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }
}

// MARK: - Outline data source and delegate

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarNode)?.isGroup ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "row")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(field)
            cell.textField = field

            if node.isGroup {
                field.font = Theme.sectionLabel
                field.textColor = .tertiaryLabelColor
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                cell.addSubview(image)
                cell.imageView = image
                field.font = Theme.rowName
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        cell.textField?.stringValue = node.isGroup ? node.title.uppercased() : node.title

        switch node.kind {
        case .pinned(let pinned):
            cell.imageView?.image = SidebarIcon.image(for: pinned)
            // A shortcut whose folder has gone is dimmed rather than removed;
            // an unplugged drive comes back.
            cell.textField?.textColor = pinned.exists ? .labelColor : .tertiaryLabelColor
            cell.toolTip = pinned.url.path
        case .treeFolder(let url), .treeFile(let url):
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
            cell.textField?.textColor = .labelColor
            cell.toolTip = url.path
        case .treeMore:
            cell.imageView?.image = NSImage(
                systemSymbolName: "ellipsis.circle", accessibilityDescription: "More files"
            )
            // Not a file, so it does not read as one.
            cell.textField?.textColor = .secondaryLabelColor
            cell.toolTip = "Show the rest of the files in this folder"
        case .volume(let url, _):
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
            cell.textField?.textColor = .labelColor
            cell.toolTip = url.path
        case .savedSearch(let search):
            cell.imageView?.image = NSImage(
                systemSymbolName: "magnifyingglass.circle", accessibilityDescription: "Saved search"
            )
            // A search whose folder has gone still runs, against the pane's
            // folder instead, and says so rather than looking broken.
            cell.textField?.textColor = search.rootIsMissing ? .tertiaryLabelColor : .labelColor
            cell.toolTip = search.rootIsMissing
                ? "\(search.text) — \(search.subtitle) (saved folder is gone; runs in the current folder)"
                : "\(search.text) — \(search.subtitle)"
        case .userGroup, .systemGroup:
            break
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        report(selectionOf: node)
    }

    /// Passes a selected row on to the delegate, which navigates the focused
    /// pane to it. A selection the sidebar made itself is dropped: it came from
    /// the pane in the first place, and sending it back navigates the pane a
    /// second time and pushes a back-history entry for a folder it never left.
    func report(selectionOf node: SidebarNode) {
        guard !isRevealingSelection else { return }
        if case .savedSearch(let search) = node.kind {
            // Arrow keys land here once per row they pass over, and a saved
            // search costs a sheet and a disk scan. Only a deliberate
            // activation is allowed to spend that; a key that merely moves
            // the selection is not.
            guard Self.selectionActivates(NSApp?.currentEvent) else { return }
            delegate?.sidebar(self, run: search)
            return
        }
        if case .treeMore = node.kind {
            // Expanding replaces the row and drops the selection, which would
            // strand an arrow-key traversal in the middle of the list.
            guard Self.selectionActivates(NSApp?.currentEvent) else { return }
            expand(more: node)
            return
        }
        if case .treeFile(let url) = node.kind {
            guard Self.selectionActivates(NSApp?.currentEvent) else { return }
            // A file is not somewhere to navigate to. The pane opens the folder
            // holding it and puts the selection on it, which is what clicking a
            // file in a tree is asking for.
            navigationOrigin = node.kind
            delegate?.sidebar(self, revealFile: url)
            DispatchQueue.main.async { [weak self] in self?.navigationOrigin = nil }
            return
        }
        guard let url = node.url else { return }

        // Navigating the pane makes it report its new folder, which brings the
        // tree down to it, synchronously and inside this call. reveal() takes a
        // copy that outlives this line, so clearing here is safe.
        navigationOrigin = node.kind
        delegate?.sidebar(self, didSelect: url)
        navigationOrigin = nil
    }

    /// Whether a reveal should move the selected row.
    ///
    /// Only when the tree itself was what moved the pane. Anything else — a
    /// double-click in the file list, Back, the path bar, a pinned folder —
    /// leaves the sidebar exactly where it was. It used to follow along and
    /// scroll the clicked folder to the top, which moved the highlight out
    /// from under whatever the user was looking at.
    static func revealMovesSelection(navigatedFrom origin: SidebarNode.Kind?) -> Bool {
        guard let origin else { return false }
        switch origin {
        case .treeFolder, .treeFile, .treeMore: return true
        case .pinned, .volume, .savedSearch, .userGroup, .systemGroup: return false
        }
    }

    /// Whether the gesture behind a selection change asks for the row to be
    /// acted on, not merely stepped over.
    ///
    /// Arrow keys change the selection one row at a time, so a row that runs
    /// work on selection would fire on every step of a keyboard traversal.
    /// A key that only moves the selection is not a request to do anything;
    /// Return and keypad Enter are, and so is any mouse gesture.
    static func selectionActivates(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        return key == UInt32(NSCarriageReturnCharacter) || key == UInt32(NSEnterCharacter)
    }

    /// Acts on the selected row, for Return and for a click on a row that was
    /// already selected. Only the kinds the selection gate holds back need
    /// this; the rest already navigated when the selection landed on them.
    private func activateSelectedRow() {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        switch node.kind {
        case .savedSearch, .treeMore, .treeFile:
            report(selectionOf: node)
        case .pinned, .volume, .treeFolder, .userGroup, .systemGroup:
            break
        }
    }

    /// Swaps a "more files" row for the files it stands for.
    ///
    /// The row is replaced rather than added to, so opening it twice cannot
    /// list the same files twice, and it leaves nothing to click a second time.
    private func expand(more node: SidebarNode) {
        guard case .treeMore(let parent, let hidden) = node.kind,
              let owner = self.owner(of: node),
              let index = owner.children.firstIndex(where: { $0 === node })
        else { return }

        owner.children.replaceSubrange(
            index...index, with: hidden.map { SidebarNode(.treeFile($0)) }
        )
        suppressingSelectionReports {
            outline.reloadItem(owner, reloadChildren: true)
            outline.expandItem(owner)
            // The clicked row is gone; leaving the highlight on whatever slid
            // into its index would look like a file had been chosen.
            outline.deselectAll(nil)
        }
        Log.debug(.ui, "Tree: showed \(hidden.count) more files under \(parent.lastPathComponent)")
    }

    /// The node holding `node`, or nil if it is a root.
    private func owner(of node: SidebarNode) -> SidebarNode? {
        var stack = roots
        while let candidate = stack.popLast() {
            if candidate.children.contains(where: { $0 === node }) { return candidate }
            stack.append(contentsOf: candidate.children)
        }
        return nil
    }

    /// Which origin applies to this step of a reveal walk.
    ///
    /// Only the first step knows what was clicked. Every step after it is a
    /// callback from a background directory read, by which time the click is
    /// long over, so the answer has to be carried rather than re-read.
    static func carriedOrigin(
        fresh: Bool, clicked: SidebarNode.Kind?, carried: SidebarNode.Kind?
    ) -> SidebarNode.Kind? {
        fresh ? clicked : carried
    }

    /// Builds the rows for one loaded level: folders, then the files that fit,
    /// then a row standing in for the rest.
    static func nodes(for level: FolderTree.Level, in parent: URL) -> [SidebarNode] {
        var nodes = level.folders.map { SidebarNode(.treeFolder($0)) }
        nodes += level.files.map { SidebarNode(.treeFile($0)) }
        if level.hasOverflow {
            nodes.append(SidebarNode(.treeMore(parent: parent, hidden: level.overflow)))
        }
        return nodes
    }

    /// Runs `body` with selection changes kept from the delegate.
    func suppressingSelectionReports(_ body: () -> Void) {
        let wasSuppressed = isRevealingSelection
        isRevealingSelection = true
        defer { isRevealingSelection = wasSuppressed }
        body()
    }

    /// Loads a tree folder's children the first time it opens. The listing is
    /// read on a background queue; a slow or permission-gated folder must not
    /// freeze the sidebar.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? SidebarNode, case .treeFolder(let url) = node.kind,
              !node.childrenLoaded
        else { return true }

        node.childrenLoaded = true
        treeLoadsInFlight += 1
        FolderTree.loadChildren(of: url, showHidden: Prefs.showHiddenFiles) { [weak self, weak node] level in
            guard let self else { return }
            // Counted down before anything else, so the restore pass below
            // sees this load as finished rather than still pending.
            self.treeLoadsInFlight -= 1
            guard let node else { return }
            // Read before the reload: whether this folder is still open, or
            // the user collapsed it while the listing was being read.
            let wasExpanded = self.outline.isItemExpanded(node)
            node.children = Self.nodes(for: level, in: url)
            self.outline.reloadItem(node, reloadChildren: true)
            // Carry on down to whatever was being revealed. Without this the
            // tree opens one level per call and stops, so following the pane
            // into a deep folder never gets past the first step.
            if let target = self.pendingReveal { self.reveal(target, continuing: true) }
            // Same again for the folders that were open when the app last
            // quit: each load reveals the next level down that has to open.
            self.restoreExpandedFolders()
            // A folder holding only files has nothing to show. Leaving it open
            // draws a disclosure triangle pointing down at nothing. A folder
            // the user collapsed during the load stays collapsed: re-opening
            // it would reverse the collapse and write the path straight back
            // into the remembered list.
            if node.children.isEmpty {
                self.outline.collapseItem(node)
            } else if wasExpanded {
                self.outline.expandItem(node)
            }
        }
        return true
    }

    /// What walking the tree towards a folder found.
    struct RevealWalk {
        /// The nodes on the way down, root first. Each is opened.
        var open: [SidebarNode] = []
        /// The first node on the way down whose children have not been read
        /// yet. The walk stops there and resumes when the load calls back.
        var pending: SidebarNode?
        /// The node for the folder itself, set only when the walk reached the
        /// end of the chain.
        var target: SidebarNode?
    }

    /// Walks `chain` down from `level`, collecting the nodes to open.
    ///
    /// `target` stays nil when the chain runs out early. The tree cannot show
    /// every folder: a hidden one is absent while hidden files are off, and a
    /// folder made after its parent was expanded is absent from that parent's
    /// cached children, which are never re-read. This used to fall back to the
    /// last ancestor it did find, and reveal() selected that ancestor, which
    /// navigated the focused pane back up out of the folder just entered.
    static func revealWalk(chain: [URL], from level: [SidebarNode]) -> RevealWalk {
        var walk = RevealWalk()
        var level = level

        for step in chain {
            guard let node = level.first(where: {
                $0.url?.standardizedFileURL == step.standardizedFileURL
            }) else { return walk }
            walk.open.append(node)
            if !node.childrenLoaded {
                walk.pending = node
                return walk
            }
            level = node.children
        }

        walk.target = walk.open.last
        return walk
    }

    /// Opens the tree down to `url` and selects it, so the tree follows the
    /// pane rather than drifting out of step with it. `continuing` is set
    /// only by the load completion that resumes a pending walk; every other
    /// caller starts a fresh one.
    func reveal(_ url: URL, continuing: Bool = false) {
        guard Prefs.showFolderTree else { return }
        guard let treeGroup = roots.first(where: {
            if case .systemGroup(let title) = $0.kind { return title == "Folders" }
            return false
        }) else { return }

        // A fresh walk starts from what was just clicked; only the load
        // callback that resumes a pending walk keeps what the first step
        // recorded, and it says so itself. It cannot be inferred: pane-driven
        // reveals — Back, the path bar, a tab switch — also arrive with no
        // navigationOrigin, and reading "no origin while a walk is pending"
        // as a continuation carried an abandoned tree click's origin onto
        // them and moved a selection the pane never asked to move.
        revealOrigin = Self.carriedOrigin(
            fresh: !continuing,
            clicked: navigationOrigin, carried: revealOrigin
        )
        pendingReveal = url
        outline.expandItem(treeGroup)

        // The chain is trimmed against the roots this tree was built with.
        // Asking FolderTree for a fresh mount list here would stat every
        // volume on the main thread once per navigation, and a dead network
        // mount turns that into a beachball on every folder click.
        let rootURLs = treeGroup.children.compactMap { node -> URL? in
            if case .treeFolder(let root) = node.kind { return root }
            return nil
        }
        let walk = Self.revealWalk(
            chain: FolderTree.chain(to: url, roots: rootURLs), from: treeGroup.children
        )
        for node in walk.open { outline.expandItem(node) }

        // Expanding started that node's load; the completion calls back into
        // here to take the next step down.
        if walk.pending != nil { return }

        // Either the folder was reached or the tree cannot show it. Nothing
        // further is going to arrive for this one.
        pendingReveal = nil
        let origin = revealOrigin
        revealOrigin = nil

        guard let target = walk.target else { return }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return }

        // The tree still opens down to the folder either way; only the
        // highlight is withheld, so a clicked favourite stays the selected row.
        guard Self.revealMovesSelection(navigatedFrom: origin) else { return }

        suppressingSelectionReports {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        // Only scroll for a row that is genuinely off screen, and never for a
        // pane the sidebar did not move. Scrolling unconditionally is what put
        // the opened folder at the top on every navigation.
        if !outline.visibleRect.intersects(outline.rect(ofRow: row)) {
            outline.scrollRowToVisible(row)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        setCollapsed(true, from: notification)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        setCollapsed(false, from: notification)
    }

    private func setCollapsed(_ collapsed: Bool, from notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }

        // A tree folder has no group to record it against, so its own open
        // state used to be dropped on the floor and the tree came back closed
        // on every launch.
        if case .treeFolder(let url) = node.kind {
            // Not while restoring: expanding a folder to put the tree back the
            // way it was would otherwise rewrite the very list being read.
            guard !isRestoringTree else { return }
            Prefs.expandedTreeFolders = Self.remembering(
                url.path, expanded: !collapsed, in: Prefs.expandedTreeFolders,
                roots: treeRootPaths()
            )
            return
        }

        guard let id = node.groupID,
              let index = SidebarStore.layout.groups.firstIndex(where: { $0.id == id }),
              SidebarStore.layout.groups[index].isCollapsed != collapsed
        else { return }
        var layout = SidebarStore.layout
        layout.groups[index].isCollapsed = collapsed
        SidebarStore.layout = layout
    }

    /// Reopens the folders that were open when the app last quit.
    ///
    /// The tree loads one level per background read, so this cannot open a
    /// deep folder in one pass. It opens whatever it can reach now; each load
    /// calls it again, and it walks one level further down. It stops when a
    /// pass opens nothing, which is either "all done" or "the rest is gone".
    func restoreExpandedFolders() {
        guard Prefs.showFolderTree, !pendingRestore.isEmpty else { return }
        guard let treeGroup = roots.first(where: {
            if case .systemGroup(let title) = $0.kind { return title == "Folders" }
            return false
        }) else { return }

        isRestoringTree = true
        defer { isRestoringTree = false }

        outline.expandItem(treeGroup)
        var opened = false
        var stillMissing: [String] = []

        for path in pendingRestore {
            guard let node = treeNode(forPath: path, under: treeGroup.children) else {
                // Its parent may not have loaded yet, so this is not proof the
                // folder has gone. It is retried after the next level lands.
                stillMissing.append(path)
                continue
            }
            if !outline.isItemExpanded(node) {
                outline.expandItem(node)
                opened = true
            }
        }

        // Nothing opened and nothing left to find: whatever remains is a
        // folder that has been deleted or is no longer readable. While any
        // listing is still being read, a miss proves nothing — the level a
        // missing folder lives in may simply not have arrived yet, so the
        // list is kept for the pass that load's completion will run.
        pendingRestore = (opened || treeLoadsInFlight > 0) ? stillMissing : []
    }

    /// The tree's root rows, read from the nodes the sidebar already built.
    /// Enumerating mounted volumes afresh would touch the filesystem, which
    /// can stall on a dead network mount; the built nodes are what the tree
    /// shows, so they are also the honest answer.
    private func treeRootPaths() -> [String] {
        guard let treeGroup = roots.first(where: {
            if case .systemGroup(let title) = $0.kind { return title == "Folders" }
            return false
        }) else { return [] }
        return treeGroup.children.compactMap { node -> String? in
            if case .treeFolder(let url) = node.kind { return url.path }
            return nil
        }
    }

    /// The node standing for `path`, searched only through levels already
    /// loaded. Nothing here reads the disk.
    func treeNode(forPath path: String, under nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if case .treeFolder(let url) = node.kind {
                if url.path == path { return node }
                // Only descend where the answer could be. The boot volume's
                // path is already "/", so appending a slash would ask for a
                // "//" prefix that no absolute path has, and nothing under
                // that root would ever be found.
                let prefix = url.path == "/" ? "/" : url.path + "/"
                if path.hasPrefix(prefix),
                   let found = treeNode(forPath: path, under: node.children) {
                    return found
                }
            }
        }
        return nil
    }

    /// Adds or removes one path, keeping the rest in the order they were
    /// opened. Shallow folders come first, so replaying the list opens a parent
    /// before the child that needs it. `roots` is the tree's root rows: a
    /// collapse never forgets what is open under a root nested inside the
    /// collapsed folder, because that root keeps its own row and its own
    /// open state.
    static func remembering(
        _ path: String, expanded: Bool, in paths: [String], roots: [String] = []
    ) -> [String] {
        var paths = paths.filter { $0 != path }
        guard expanded else {
            // Closing a folder closes what is inside it; leaving descendants
            // listed would reopen them the next time this one is opened. The
            // boot volume's path is already "/", so appending a slash would
            // filter on a "//" prefix and leave every descendant behind.
            let prefix = path == "/" ? "/" : path + "/"
            // The list does not record which root a path was opened under,
            // and home and every mounted volume sit somewhere under "/". A
            // plain prefix wipe for "/" therefore matched every stored path
            // and erased the open state of every other root in one stroke.
            // A root inside the closed folder shields its own subtree.
            let shielded = roots.filter { $0 != path && $0.hasPrefix(prefix) }
            return paths.filter { stored in
                guard stored.hasPrefix(prefix) else { return true }
                return shielded.contains { stored == $0 || stored.hasPrefix($0 + "/") }
            }
        }
        paths.append(path)
        return paths.sorted { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, let id = node.itemID else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.uuidString, forType: Self.itemDragType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // AppKit proposes the row under the pointer when the pointer is over an
        // item, and the group with a child index only when it is exactly
        // between two rows. Refusing the first meant the only drop that was
        // ever accepted arrived with index -1, which was read as "append", so
        // every drag landed at the bottom whatever it was aimed at. Retarget a
        // drop on a row onto that row's group, at that row's position.
        var target = item as? SidebarNode
        if let row = target, row.groupID == nil {
            guard let parent = outlineView.parent(forItem: row) as? SidebarNode,
                  parent.groupID != nil else { return [] }
            outlineView.setDropItem(parent, dropChildIndex: outlineView.childIndex(forItem: row))
            target = parent
        }

        // Only user groups accept drops; Locations is derived from the system.
        guard let target, target.groupID != nil else { return [] }

        if info.draggingPasteboard.string(forType: Self.itemDragType) != nil { return .move }

        let dropped = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return dropped.contains { $0.hasDirectoryPath } ? .copy : []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let target = item as? SidebarNode, let groupID = target.groupID else { return false }
        var layout = SidebarStore.layout

        if let raw = info.draggingPasteboard.string(forType: Self.itemDragType),
           let itemID = UUID(uuidString: raw) {
            let position = index < 0 ? (layout.group(id: groupID)?.items.count ?? 0) : index
            layout.move(itemID: itemID, toGroup: groupID, at: position)
            SidebarStore.layout = layout
            return true
        }

        let dropped = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let folders = dropped.filter(\.hasDirectoryPath)
        guard !folders.isEmpty else { return false }

        // Inserted where they were dropped, in the order they were dragged.
        // Appending regardless is what made a drop aimed at the top of the
        // list appear at the bottom.
        let start = index < 0 ? (layout.group(id: groupID)?.items.count ?? 0) : index
        for (offset, folder) in folders.enumerated() {
            layout.insertItem(SidebarItem(path: folder.path), toGroup: groupID, at: start + offset)
        }
        SidebarStore.layout = layout
        return true
    }
}

/// Picks an icon: an SF Symbol from a short list, any emoji, or the file's own.
enum IconPicker {
    /// Returns the chosen icon name, an empty string to clear it, or nil when
    /// cancelled.
    static func run(current: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Change Icon"
        alert.informativeText = "Pick a symbol, or type any emoji. Leave empty to use the folder's own icon."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Use Folder Icon")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = "Emoji or SF Symbol name"

        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.spacing = 2
        grid.translatesAutoresizingMaskIntoConstraints = false

        // A row of one-click symbols; the field stays available for anything else.
        let setter = FieldSetter(field: field)
        for symbol in SidebarIcon.suggestedSymbols.prefix(12) {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                                    ?? NSImage(), target: nil, action: nil)
            button.bezelStyle = .smallSquare
            button.isBordered = false
            button.setAccessibilityLabel(symbol)
            // The symbol travels on the button. It used to be looked up in a
            // process-wide table keyed by ObjectIdentifier(button), i.e. the
            // button's address, which neither retained the buttons nor dropped
            // their entries when the alert went away. A later run whose buttons
            // were allocated at addresses the previous run had freed matched
            // the stale entries, so clicking a symbol wrote into a text field
            // that was no longer on screen.
            button.identifier = NSUserInterfaceItemIdentifier(symbol)
            button.target = setter
            button.action = #selector(FieldSetter.set(_:))
            grid.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [field, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        // A control does not retain its target, so this run's setter is held
        // for as long as its buttons are on screen.
        let response = withExtendedLifetime(setter) { alert.runModal() }

        switch response {
        case .alertFirstButtonReturn: return field.stringValue.trimmingCharacters(in: .whitespaces)
        case .alertSecondButtonReturn: return ""
        default: return nil
        }
    }

    /// Routes a symbol button back into the text field. One setter per run of
    /// the picker: it holds that run's field, and goes when the run does.
    final class FieldSetter: NSObject {
        private let field: NSTextField

        init(field: NSTextField) {
            self.field = field
        }

        @objc func set(_ sender: NSButton) {
            guard let symbol = sender.identifier?.rawValue, !symbol.isEmpty else { return }
            field.stringValue = symbol
        }
    }
}
