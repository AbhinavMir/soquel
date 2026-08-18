import Foundation

/// Application preferences and session state, stored in settings.json.
enum Prefs {
    private static var d: SettingsStore { Settings }

    /// Every key Prefs owns, used to migrate an existing defaults database and
    /// to document the file's contents in the settings window.
    static let keys = [
        "showHiddenFiles", "foldersFirst", "favouritePaths", "viewMode",
        "showFolderTree", "showInspector", "showGitStatus", "calculateFolderSizes",
        "autoFitColumns", "iconSize", "sortOrder", "terminalBundleID", "keyboardFirst",
        "columnViewWidth", "expandedTreeFolders",
        "editorBundleID", "sessionPanes", "sessionActiveTabs", "welcomeShown",
        "syncBrowsing", "checkForUpdates", "lastUpdateCheck", "skippedUpdateVersion",
        "sortOrderDefaultMigrated", "hideFromScreenSharing",
    ]

    /// Whether the app's windows are left out of screen sharing and
    /// recording. Remembered, so it stays on for the length of a call rather
    /// than needing to be set again for every window.
    static var hideFromScreenSharing: Bool {
        get { d.bool(forKey: "hideFromScreenSharing") }
        set { d.set(newValue, forKey: "hideFromScreenSharing") }
    }

    static var showHiddenFiles: Bool {
        get { d.bool(forKey: "showHiddenFiles") }
        set { d.set(newValue, forKey: "showHiddenFiles") }
    }

    /// The sort that shipped before the default became newest-first.
    static let legacyDefaultSortOrder = SortOrder(
        descriptors: [SortDescriptorSpec(key: .name, ascending: true)]
    )

    /// Moves anyone still on the old default onto the new one, once.
    ///
    /// A stored value beats a default, and the old default was written to the
    /// file the first time anything touched the sort — so without this the
    /// change reaches new installs only, and the people who already have the
    /// application never see it. Only an exact match for the old default is
    /// replaced: a sort somebody actually chose is theirs and is left alone.
    static func migrateSortOrderDefault() {
        let marker = "sortOrderDefaultMigrated"
        guard d.object(forKey: marker) == nil else { return }
        d.set(true, forKey: marker)

        guard let stored = d.decode(SortOrder.self, forKey: "sortOrder"),
              stored == legacyDefaultSortOrder
        else { return }
        d.set(nil, forKey: "sortOrder")
    }

    /// Off. Grouping folders above files means the sort only applies inside
    /// each group, so "newest first" shows the newest folder and the newest
    /// file separately rather than the newest thing.
    static var foldersFirst: Bool {
        get { d.object(forKey: "foldersFirst") as? Bool ?? false }
        set { d.set(newValue, forKey: "foldersFirst") }
    }

    static var favouritePaths: [String] {
        get { d.stringArray(forKey: "favouritePaths") ?? [] }
        set { d.set(newValue, forKey: "favouritePaths") }
    }

    /// View settings are global on purpose: a folder looks the same wherever
    /// you reach it from.
    static var viewMode: ViewMode {
        get { ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .list }
        set { d.set(newValue.rawValue, forKey: "viewMode") }
    }

    /// Kept so the icon-view toolbar toggle and older stored settings still work.
    static var viewModeIsIcon: Bool {
        get { viewMode == .icon }
        set { viewMode = newValue ? .icon : .list }
    }

    /// The browsable folder tree in the sidebar.
    static var showFolderTree: Bool {
        get { d.object(forKey: "showFolderTree") as? Bool ?? true }
        set { d.set(newValue, forKey: "showFolderTree") }
    }

    /// Which folders in the sidebar tree were left open.
    ///
    /// Paths rather than nodes: the tree is rebuilt from disk on every launch,
    /// so there is no object to remember, and a folder that has since been
    /// deleted simply fails to be found again.
    static var expandedTreeFolders: [String] {
        get { d.stringArray(forKey: "expandedTreeFolders") ?? [] }
        // Bounded because opening a deep tree once should not leave a
        // thousand paths to walk on every future launch.
        set { d.set(Array(newValue.suffix(200)), forKey: "expandedTreeFolders") }
    }

    /// The preview and details panel on the right.
    static var showInspector: Bool {
        get { d.object(forKey: "showInspector") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInspector") }
    }

    /// Selecting a folder in one pane shows its contents in the next one.
    static var syncBrowsing: Bool {
        get { d.object(forKey: "syncBrowsing") as? Bool ?? false }
        set { d.set(newValue, forKey: "syncBrowsing") }
    }

    /// vi-style keys in the file list: j/k to move, h/l to leave and enter.
    static var keyboardFirst: Bool {
        get { d.bool(forKey: "keyboardFirst") }
        set { d.set(newValue, forKey: "keyboardFirst") }
    }

    static var showGitStatus: Bool {
        get { d.object(forKey: "showGitStatus") as? Bool ?? true }
        set { d.set(newValue, forKey: "showGitStatus") }
    }

    /// Folder sizes cost a full tree walk each, so this is opt-in.
    static var calculateFolderSizes: Bool {
        get { d.bool(forKey: "calculateFolderSizes") }
        set { d.set(newValue, forKey: "calculateFolderSizes") }
    }

    /// Widen columns to fit the longest name in the folder, on every load.
    static var autoFitColumns: Bool {
        get { d.object(forKey: "autoFitColumns") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoFitColumns") }
    }

    static let minimumIconSize: Double = 32
    static let maximumIconSize: Double = 224

    static var iconSize: Double {
        get {
            let stored = d.double(forKey: "iconSize") ?? 72
            return Swift.min(Swift.max(stored, minimumIconSize), maximumIconSize)
        }
        set { d.set(Swift.min(Swift.max(newValue, minimumIconSize), maximumIconSize), forKey: "iconSize") }
    }

    /// One step of zoom. Proportional rather than a fixed number of points, so
    /// a step feels the same at 32 as it does at 200.
    static func zoomedIconSize(from size: Double, larger: Bool) -> Double {
        let stepped = larger ? size * 1.25 : size / 1.25
        return Swift.min(Swift.max(stepped.rounded(), minimumIconSize), maximumIconSize)
    }

    static var sortOrder: SortOrder {
        get {
            guard let decoded = d.decode(SortOrder.self, forKey: "sortOrder"),
                  !decoded.descriptors.isEmpty
            else { return .default }
            return decoded
        }
        set { d.encode(newValue, forKey: "sortOrder") }
    }

    /// Bundle identifier of the chosen terminal; nil means "first installed".
    static var terminalBundleID: String? {
        get { d.string(forKey: "terminalBundleID") }
        set { d.set(newValue, forKey: "terminalBundleID") }
    }

    static var editorBundleID: String? {
        get { d.string(forKey: "editorBundleID") }
        set { d.set(newValue, forKey: "editorBundleID") }
    }

    /// One entry per pane; each entry is the pane's tab paths in order.
    static var sessionPanes: [[String]] {
        get { (d.array(forKey: "sessionPanes") as? [[String]]) ?? [] }
        set { d.set(newValue, forKey: "sessionPanes") }
    }

    static var sessionActiveTabs: [Int] {
        get { (d.array(forKey: "sessionActiveTabs") as? [Int]) ?? [] }
        set { d.set(newValue, forKey: "sessionActiveTabs") }
    }
}

/// Writes to stderr when SOQUEL_DEBUG is set. Used to trace window and
/// navigation lifecycle while diagnosing; silent in normal runs.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SOQUEL_DEBUG"] != nil else { return }
    FileHandle.standardError.write(("[soquel] " + message() + "\n").data(using: .utf8)!)
}
