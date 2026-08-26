import Foundation

/// What a folder is for, and where things are allowed to go.
///
/// Two separate ideas, kept apart on purpose:
///
/// - **Context** is a sentence you write about a folder — "invoices, one per
///   month, named by date". It travels with the folder and is given to the
///   model whenever that folder is cleaned or is a candidate destination.
/// - **Global** marks a folder as somewhere things may be filed from anywhere
///   else. `~/test1/abc` can be emptied into `~/test2/abc` when the second is
///   global, with no context written at all — the mark is the instruction.
enum FolderContext {
    // MARK: - Context

    /// Path → the sentence written about it.
    static var notes: [String: String] {
        get { Settings.object(forKey: "folderContext") as? [String: String] ?? [:] }
        set { Settings.set(newValue, forKey: "folderContext") }
    }

    static func note(for folder: URL) -> String? {
        let text = notes[folder.standardizedFileURL.path]
        return (text?.isEmpty ?? true) ? nil : text
    }

    static func setNote(_ text: String?, for folder: URL) {
        var all = notes
        let key = folder.standardizedFileURL.path
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { all[key] = trimmed } else { all.removeValue(forKey: key) }
        notes = all
    }

    // MARK: - Global folders

    /// Folders things may be filed into from anywhere.
    static var globals: [String] {
        get { Settings.object(forKey: "globalFolders") as? [String] ?? [] }
        set { Settings.set(Array(Set(newValue)).sorted(), forKey: "globalFolders") }
    }

    static func isGlobal(_ folder: URL) -> Bool {
        globals.contains(folder.standardizedFileURL.path)
    }

    static func setGlobal(_ global: Bool, for folder: URL) {
        let key = folder.standardizedFileURL.path
        var all = globals
        if global {
            all.append(key)
        } else {
            all.removeAll { $0 == key }
        }
        globals = all
    }

    /// Every global folder that still exists, with whatever was written about
    /// it. A folder that has gone is dropped rather than offered as somewhere
    /// to move files to.
    static func destinations() -> [(url: URL, note: String?)] {
        var alive: [String] = []
        var result: [(URL, String?)] = []
        for path in globals {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            alive.append(path)
            let url = URL(fileURLWithPath: path)
            result.append((url, note(for: url)))
        }
        if alive.count != globals.count { globals = alive }
        return result
    }

    /// Whether a destination is somewhere a plan is allowed to put a file.
    ///
    /// Inside the folder being cleaned, or inside a folder marked global.
    /// Nowhere else — a suggestion that moved files to an arbitrary path would
    /// be a model choosing where somebody's files live.
    static func isAllowedDestination(_ url: URL, cleaning folder: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let roots = [folder.standardizedFileURL.path] + destinations().map(\.url.path)
        return roots.contains { target == $0 || target.hasPrefix($0 + "/") }
    }
}
