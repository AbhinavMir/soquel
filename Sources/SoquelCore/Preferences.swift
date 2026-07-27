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
        "editorBundleID", "sessionPanes", "sessionActiveTabs",
    ]

    static var showHiddenFiles: Bool {
        get { d.bool(forKey: "showHiddenFiles") }
        set { d.set(newValue, forKey: "showHiddenFiles") }
    }

    static var foldersFirst: Bool {
        get { d.object(forKey: "foldersFirst") as? Bool ?? true }
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

    /// The preview and details panel on the right.
    static var showInspector: Bool {
        get { d.object(forKey: "showInspector") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInspector") }
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

    static var iconSize: Double {
        get { d.double(forKey: "iconSize") ?? 72 }
        set { d.set(newValue, forKey: "iconSize") }
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
