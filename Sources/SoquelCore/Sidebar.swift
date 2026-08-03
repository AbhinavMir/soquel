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
        outline = NSOutlineView()
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
            delegate?.sidebar(self, run: search)
            return
        }
        if case .treeMore = node.kind {
            expand(more: node)
            return
        }
        if case .treeFile(let url) = node.kind {
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
    /// It should when the tree is catching up with a pane the user moved some
    /// other way — a double-click in the file list, Back, the path bar. It
    /// should not when the pane moved because a pinned folder or a volume was
    /// clicked in this very sidebar: that row is the selection, and replacing
    /// it with the tree's node for the same folder takes the highlight off
    /// what was chosen and drops it somewhere the user was not looking.
    static func revealMovesSelection(navigatedFrom origin: SidebarNode.Kind?) -> Bool {
        guard let origin else { return true }
        switch origin {
        case .treeFolder, .treeFile, .treeMore: return true
        case .pinned, .volume, .savedSearch, .userGroup, .systemGroup: return false
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
        FolderTree.loadChildren(of: url, showHidden: Prefs.showHiddenFiles) { [weak self, weak node] level in
            guard let self, let node else { return }
            node.children = Self.nodes(for: level, in: url)
            self.outline.reloadItem(node, reloadChildren: true)
            // Carry on down to whatever was being revealed. Without this the
            // tree opens one level per call and stops, so following the pane
            // into a deep folder never gets past the first step.
            if let target = self.pendingReveal { self.reveal(target) }
            // A folder holding only files has nothing to show. Leaving it open
            // draws a disclosure triangle pointing down at nothing.
            if node.children.isEmpty {
                self.outline.collapseItem(node)
            } else {
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
    /// pane rather than drifting out of step with it.
    func reveal(_ url: URL) {
        guard Prefs.showFolderTree else { return }
        guard let treeGroup = roots.first(where: {
            if case .systemGroup(let title) = $0.kind { return title == "Folders" }
            return false
        }) else { return }

        // A fresh walk starts from what was just clicked; a continuation keeps
        // whatever the first step recorded.
        revealOrigin = Self.carriedOrigin(
            fresh: pendingReveal == nil, clicked: navigationOrigin, carried: revealOrigin
        )
        pendingReveal = url
        outline.expandItem(treeGroup)

        let walk = Self.revealWalk(chain: FolderTree.chain(to: url), from: treeGroup.children)
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
        outline.scrollRowToVisible(row)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        setCollapsed(true, from: notification)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        setCollapsed(false, from: notification)
    }

    private func setCollapsed(_ collapsed: Bool, from notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode,
              let id = node.groupID,
              let index = SidebarStore.layout.groups.firstIndex(where: { $0.id == id }),
              SidebarStore.layout.groups[index].isCollapsed != collapsed
        else { return }
        var layout = SidebarStore.layout
        layout.groups[index].isCollapsed = collapsed
        SidebarStore.layout = layout
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
