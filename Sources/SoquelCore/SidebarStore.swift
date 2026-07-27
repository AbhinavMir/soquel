import AppKit

/// A pinned location in the sidebar.
struct SidebarItem: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var path: String
    /// Shown instead of the folder's own name. Renaming here never touches the
    /// folder on disk.
    var displayName: String?
    /// An emoji, an SF Symbol name, or nil for the file's own icon.
    var icon: String?

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// A user-named section of the sidebar.
struct SidebarGroup: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var items: [SidebarItem] = []
    var isCollapsed: Bool = false
}

/// The user's sidebar layout: groups of pinned locations, persisted as JSON.
///
/// Kept separate from the built-in Places and Locations sections, which are
/// derived from the system and are not editable.
struct SidebarLayout: Codable, Equatable {
    var groups: [SidebarGroup]

    static var defaultLayout: SidebarLayout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SidebarLayout(groups: [
            SidebarGroup(title: "Favourites", items: [
                SidebarItem(path: home.path, icon: "house"),
                SidebarItem(path: home.appendingPathComponent("Desktop").path, icon: "menubar.dock.rectangle"),
                SidebarItem(path: home.appendingPathComponent("Documents").path, icon: "doc"),
                SidebarItem(path: home.appendingPathComponent("Downloads").path, icon: "arrow.down.circle"),
                SidebarItem(path: "/Applications", icon: "square.grid.2x2"),
            ].filter(\.exists)),
        ])
    }

    // MARK: - Lookups

    func group(id: UUID) -> SidebarGroup? { groups.first { $0.id == id } }

    func indexOfGroup(containing itemID: UUID) -> Int? {
        groups.firstIndex { $0.items.contains { $0.id == itemID } }
    }

    func item(id: UUID) -> SidebarItem? {
        groups.flatMap(\.items).first { $0.id == id }
    }

    var containsAnyItem: Bool { groups.contains { !$0.items.isEmpty } }

    /// The pinned entry for a folder, wherever it is filed.
    ///
    /// Compared on the standardised URL, so ~/Documents and /Users/x/Documents
    /// are the same pin rather than two.
    func pin(for url: URL) -> SidebarItem? {
        let wanted = url.standardizedFileURL
        for group in groups {
            if let found = group.items.first(where: { $0.url.standardizedFileURL == wanted }) {
                return found
            }
        }
        return nil
    }

    func isPinned(_ url: URL) -> Bool { pin(for: url) != nil }

    // MARK: - Mutation

    mutating func addItem(_ item: SidebarItem, toGroup groupID: UUID? = nil) {
        let index = groupID.flatMap { id in groups.firstIndex { $0.id == id } } ?? 0
        guard groups.indices.contains(index) else {
            groups.append(SidebarGroup(title: "Favourites", items: [item]))
            return
        }
        // Pinning something already pinned in that group is a no-op rather than
        // a duplicate row.
        guard !groups[index].items.contains(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL })
        else { return }
        groups[index].items.append(item)
    }

    /// Adds an item at a position, for a drop aimed somewhere in particular.
    /// `addItem` always appends, which is right for a menu command and wrong
    /// for a drag.
    mutating func insertItem(_ item: SidebarItem, toGroup groupID: UUID, at index: Int) {
        guard let group = groups.firstIndex(where: { $0.id == groupID }) else {
            addItem(item, toGroup: groupID)
            return
        }
        guard !groups[group].items.contains(where: {
            $0.url.standardizedFileURL == item.url.standardizedFileURL
        }) else { return }
        groups[group].items.insert(item, at: max(0, min(index, groups[group].items.count)))
    }

    mutating func removeItem(id: UUID) {
        for index in groups.indices {
            groups[index].items.removeAll { $0.id == id }
        }
    }

    mutating func updateItem(id: UUID, transform: (inout SidebarItem) -> Void) {
        for groupIndex in groups.indices {
            guard let itemIndex = groups[groupIndex].items.firstIndex(where: { $0.id == id }) else { continue }
            transform(&groups[groupIndex].items[itemIndex])
            return
        }
    }

    mutating func addGroup(title: String) -> UUID {
        let group = SidebarGroup(title: title)
        groups.append(group)
        return group.id
    }

    mutating func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    mutating func renameGroup(id: UUID, to title: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].title = title
    }

    /// Moves an item to a position in a group, for drag reordering. The target
    /// index is interpreted after the item has been lifted out.
    mutating func move(itemID: UUID, toGroup groupID: UUID, at index: Int) {
        guard let sourceGroup = indexOfGroup(containing: itemID),
              let sourceIndex = groups[sourceGroup].items.firstIndex(where: { $0.id == itemID }),
              let targetGroup = groups.firstIndex(where: { $0.id == groupID })
        else { return }

        let item = groups[sourceGroup].items.remove(at: sourceIndex)
        var destination = index
        if sourceGroup == targetGroup && sourceIndex < index { destination -= 1 }
        destination = max(0, min(destination, groups[targetGroup].items.count))
        groups[targetGroup].items.insert(item, at: destination)
    }
}

/// Loads and saves the sidebar layout, and tells open windows when it changes.
enum SidebarStore {
    private static let key = "sidebarLayout"

    static var layout: SidebarLayout = load() {
        didSet {
            guard layout != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .soquelSidebarChanged, object: nil)
        }
    }

    private static func load() -> SidebarLayout {
        Settings.decode(SidebarLayout.self, forKey: key) ?? .defaultLayout
    }

    private static func save() {
        Settings.encode(layout, forKey: key)
    }

    static func reset() {
        layout = .defaultLayout
    }

    /// Re-reads the layout after the settings file was edited outside the app.
    static func reloadFromDisk() {
        layout = load()
    }
}

extension Notification.Name {
    static let soquelSidebarChanged = Notification.Name("app.soquel.sidebarChanged")
}

/// Lists subdirectories for the folder tree, off the main thread.
///
/// The tree is the most-requested missing piece in the research: people reject
/// column view and list-view triangles as substitutes because neither persists
/// while you browse.
enum FolderTree {
    /// Roots the tree offers: home, then any other mounted volume.
    static var roots: [URL] {
        var roots = [FileManager.default.homeDirectoryForCurrentUser]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        roots.append(contentsOf: volumes)
        return roots
    }

    /// Subdirectories of `url`, sorted by name. Packages are treated as leaves:
    /// an .app in the tree would otherwise expand into its own innards.
    static func children(of url: URL, showHidden: Bool) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: options
        ) else { return [] }

        return contents.filter { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            // A symlink to a directory is not followed: a link back up the tree
            // would expand forever.
            guard values?.isSymbolicLink != true else { return false }
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Loads children on a background queue and hands them back on the main one.
    static func loadChildren(of url: URL, showHidden: Bool, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let children = children(of: url, showHidden: showHidden)
            DispatchQueue.main.async { completion(children) }
        }
    }

    /// The chain from a root down to `url`, for revealing the active folder.
    static func chain(to url: URL) -> [URL] {
        var chain: [URL] = []
        var cursor: URL? = url.standardizedFileURL
        while let current = cursor {
            chain.append(current)
            cursor = parentDirectoryURL(of: current)
        }
        return chain.reversed()
    }
}

/// Renders a sidebar item's icon: an emoji drawn as an image, a named SF
/// Symbol, or the file's own icon.
enum SidebarIcon {
    static func image(for item: SidebarItem, size: CGFloat = 16) -> NSImage? {
        guard let icon = item.icon, !icon.isEmpty else {
            return fileIcon(for: item, size: size)
        }
        if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: item.title) {
            symbol.size = NSSize(width: size, height: size)
            return symbol
        }
        if isEmoji(icon) { return emojiImage(icon, size: size) }
        return fileIcon(for: item, size: size)
    }

    private static func fileIcon(for item: SidebarItem, size: CGFloat) -> NSImage? {
        guard item.exists else {
            return NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil)
        }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    static func isEmoji(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && (scalar.value > 0x238C || text.unicodeScalars.count > 1)
    }

    /// Draws an emoji into an image so it can sit where an icon goes.
    static func emojiImage(_ emoji: String, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.92),
        ]
        let text = emoji as NSString
        let bounds = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    /// A small, opinionated set offered in the icon picker, alongside "any
    /// emoji" and the file's own icon.
    static let suggestedSymbols = [
        "house", "star", "folder", "doc", "arrow.down.circle", "hammer",
        "briefcase", "photo", "music.note", "film", "terminal", "chevron.left.forwardslash.chevron.right",
        "paintbrush", "cube", "archivebox", "tray", "book", "graduationcap",
        "heart", "flag", "tag", "bolt", "leaf", "globe",
    ]
}
