import Foundation

/// View mode and sort remembered per folder.
///
/// Downloads wants list view sorted by date. Pictures wants icons. Holding one
/// setting for both means changing it in either is a change you did not ask
/// for in the other.
enum FolderViewSettings {
    struct Entry: Codable, Equatable {
        var viewMode: String
        var sortOrder: SortOrder?
    }

    /// Off by default. Turning it on starts recording; until then the global
    /// setting is the only one, and nothing changes for someone who liked it
    /// that way.
    static var isEnabled: Bool {
        get { Settings.object(forKey: "perFolderViewSettings") as? Bool ?? false }
        set { Settings.set(newValue, forKey: "perFolderViewSettings") }
    }

    /// Folders remembered, oldest evicted first. A file manager used for years
    /// would otherwise accumulate an entry per folder ever visited.
    static let limit = 500

    private static let key = "folderViewSettings"
    private static let orderKey = "folderViewSettingsOrder"

    static func all() -> [String: Entry] {
        guard let raw = Settings.object(forKey: key) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func entry(for url: URL) -> Entry? {
        guard isEnabled else { return nil }
        return all()[identity(of: url)]
    }

    /// The stored view mode, then Finder's, then the global one.
    ///
    /// Finder comes second: a choice made here outranks one made there, but a
    /// folder Finder already knows should be in icon view should not open as a
    /// list just because this application has never been told.
    static func viewMode(for url: URL) -> ViewMode {
        if let stored = entry(for: url)?.viewMode, let mode = ViewMode(rawValue: stored) {
            return mode
        }
        if let finder = finderSettings(for: url)?.viewMode { return finder }
        return Prefs.viewMode
    }

    static func sortOrder(for url: URL) -> SortOrder {
        if let stored = entry(for: url)?.sortOrder { return stored }
        if let finder = finderSettings(for: url), let column = finder.sortColumn,
           let key = sortKey(forFinder: column) {
            return SortOrder(descriptors: [
                SortDescriptorSpec(key: key, ascending: finder.sortAscending ?? true),
            ])
        }
        return Prefs.sortOrder
    }

    /// Finder's sort column names, in this application's terms.
    static func sortKey(forFinder name: String) -> SortKey? {
        switch name {
        case "name": return .name
        case "size", "ubsz": return .size
        case "kind": return .kind
        case "modified", "dateModified": return .modified
        case "created", "dateCreated": return .created
        default: return nil
        }
    }

    // MARK: - What Finder already knows

    /// Read once per folder per change to its `.DS_Store`.
    ///
    /// viewMode(for:) is asked on every reload and every keystroke that moves
    /// the selection, and parsing a binary tree off disk that often would be
    /// felt.
    private static var finderCache: [String: (stamp: Date?, settings: DSStore.Settings?)] = [:]
    private static let cacheLock = NSLock()

    static func finderSettings(for url: URL) -> DSStore.Settings? {
        let id = identity(of: url)
        let stamp = (try? url.appendingPathComponent(".DS_Store")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        cacheLock.lock()
        if let cached = finderCache[id], cached.stamp == stamp {
            cacheLock.unlock()
            return cached.settings
        }
        cacheLock.unlock()

        let found = DSStore.settings(for: url)

        cacheLock.lock()
        // The cache is per-folder and unbounded otherwise; a long session
        // walking a large tree would hold an entry for every folder seen.
        if finderCache.count > 400 { finderCache.removeAll() }
        finderCache[id] = (stamp, found)
        cacheLock.unlock()
        return found
    }

    static func forgetFinderCache() {
        cacheLock.lock()
        finderCache.removeAll()
        cacheLock.unlock()
    }

    static func record(_ url: URL, viewMode: ViewMode, sortOrder: SortOrder?) {
        guard isEnabled else { return }
        var table = all()
        let id = identity(of: url)
        table[id] = Entry(viewMode: viewMode.rawValue, sortOrder: sortOrder)

        var order = (Settings.stringArray(forKey: orderKey) ?? []).filter { $0 != id }
        order.append(id)
        (table, order) = evict(table: table, order: order)

        guard let data = try? JSONEncoder().encode(table),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return }
        Settings.set(object, forKey: key)
        Settings.set(order, forKey: orderKey)
    }

    /// Drops the least recently touched folders once past the limit.
    static func evict(
        table: [String: Entry], order: [String], limit: Int = limit
    ) -> ([String: Entry], [String]) {
        guard order.count > limit else { return (table, order) }
        let dropping = order.prefix(order.count - limit)
        var table = table
        for id in dropping { table.removeValue(forKey: id) }
        return (table, Array(order.dropFirst(dropping.count)))
    }

    static func forget(_ url: URL) {
        var table = all()
        let id = identity(of: url)
        guard table.removeValue(forKey: id) != nil else { return }
        let order = (Settings.stringArray(forKey: orderKey) ?? []).filter { $0 != id }
        guard let data = try? JSONEncoder().encode(table),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return }
        Settings.set(object, forKey: key)
        Settings.set(order, forKey: orderKey)
    }

    static func forgetAll() {
        Settings.set(nil, forKey: key)
        Settings.set(nil, forKey: orderKey)
    }

    /// Symlinks resolved and the trailing slash dropped, so /tmp and
    /// /private/tmp are one folder rather than two disagreeing entries.
    static func identity(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
