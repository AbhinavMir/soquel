import Foundation

extension Notification.Name {
    static let soquelSavedSearchesChanged = Notification.Name("app.soquel.savedSearchesChanged")
}

/// A search kept under a name and reopened from the sidebar.
///
/// The query is stored, not its results: a saved search is a question, and the
/// answer is whatever is true when you ask it again.
struct SavedSearch: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var text: String
    var mode: String
    var matching: String
    var scope: String
    /// Where a folder-scoped search starts. Empty for the scopes that do not
    /// need one.
    var rootPath: String
    var caseSensitive: Bool
    var includeHidden: Bool
    var includePackages: Bool
    var respectGitignore: Bool
    var maximumDepth: Int?

    init(name: String, query: FileSearch.Query) {
        self.name = name
        text = query.text
        mode = query.mode.rawValue
        matching = query.matching.rawValue
        scope = query.scope.rawValue
        rootPath = query.root.path
        caseSensitive = query.caseSensitive
        includeHidden = query.includeHidden
        includePackages = query.includePackages
        respectGitignore = query.respectGitignore
        maximumDepth = query.maximumDepth
    }

    /// Rebuilds the query. `fallbackRoot` is used when the folder the search
    /// was saved against no longer exists, so a renamed project does not turn
    /// a saved search into an error.
    func query(fallbackRoot: URL) -> FileSearch.Query {
        let saved = URL(fileURLWithPath: rootPath)
        let root = FileManager.default.fileExists(atPath: rootPath) ? saved : fallbackRoot

        var query = FileSearch.Query(text: text, root: root)
        query.mode = FileSearch.Mode(rawValue: mode) ?? .name
        query.matching = FileSearch.Matching(rawValue: matching) ?? .contains
        query.scope = FileSearch.Scope(rawValue: scope) ?? .folder
        query.caseSensitive = caseSensitive
        query.includeHidden = includeHidden
        query.includePackages = includePackages
        query.respectGitignore = respectGitignore
        query.maximumDepth = maximumDepth
        return query
    }

    /// "contents · everywhere", for the sidebar tooltip.
    var subtitle: String {
        var parts = [mode, scope]
        if respectGitignore { parts.append("git-aware") }
        return parts.joined(separator: " · ")
    }

    /// True when the folder this was saved against is gone.
    var rootIsMissing: Bool {
        scope == FileSearch.Scope.folder.rawValue
            && !FileManager.default.fileExists(atPath: rootPath)
    }
}

/// The saved searches, in settings.json alongside everything else.
enum SavedSearchStore {
    private static let key = "savedSearches"

    static var all: [SavedSearch] {
        Settings.decode([SavedSearch].self, forKey: key) ?? []
    }

    /// Saving under a name that already exists replaces it, so saving twice
    /// from the same panel updates rather than accumulating near-duplicates.
    static func save(_ search: SavedSearch) {
        var searches = all
        if let index = searches.firstIndex(where: { $0.name == search.name }) {
            var replacement = search
            replacement.id = searches[index].id
            searches[index] = replacement
        } else {
            searches.append(search)
        }
        write(searches)
    }

    static func remove(id: UUID) {
        write(all.filter { $0.id != id })
    }

    static func rename(id: UUID, to name: String) {
        var searches = all
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[index].name = name
        write(searches)
    }

    static func search(id: UUID) -> SavedSearch? {
        all.first { $0.id == id }
    }

    private static func write(_ searches: [SavedSearch]) {
        Settings.encode(searches, forKey: key)
        NotificationCenter.default.post(name: .soquelSavedSearchesChanged, object: nil)
    }
}
