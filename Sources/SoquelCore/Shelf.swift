import Foundation

extension Notification.Name {
    static let soquelShelfChanged = Notification.Name("app.soquel.shelfChanged")
}

/// Files gathered from anywhere, held until you decide where they go.
///
/// The pasteboard holds one selection from one folder. Collecting twenty files
/// from six folders means either six trips or a staging folder; the shelf is
/// that staging folder without the folder.
enum Shelf {
    private static let key = "shelfPaths"

    /// What is on the shelf, in the order it was added.
    ///
    /// Paths that no longer exist are dropped on read rather than on a timer:
    /// a shelf that offers to copy a file that was deleted an hour ago is
    /// worse than one that quietly shortens.
    static var urls: [URL] {
        let paths = Settings.stringArray(forKey: key) ?? []
        // attributesOfItem(atPath:) reports on the path itself, where
        // fileExists(atPath:) follows symlinks and would prune a shelved link
        // whose target is gone — a link that still exists and can still be
        // copied or moved, since the transfer copies the link, not through it.
        let existing = paths.filter { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }
        if existing.count != paths.count {
            Settings.set(existing, forKey: key)
        }
        return existing.map { URL(fileURLWithPath: $0) }
    }

    static var count: Int { urls.count }
    static var isEmpty: Bool { urls.isEmpty }

    /// Adds files, keeping the order and ignoring anything already there.
    /// Returns how many were actually new, so the caller can say so.
    @discardableResult
    static func add(_ incoming: [URL]) -> Int {
        var paths = (Settings.stringArray(forKey: key) ?? [])
        let known = Set(paths)
        var added = 0
        for url in incoming {
            let path = url.standardizedFileURL.path
            guard !known.contains(path) else { continue }
            paths.append(path)
            added += 1
        }
        guard added > 0 else { return 0 }
        Settings.set(paths, forKey: key)
        notify()
        return added
    }

    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (Settings.stringArray(forKey: key) ?? []).filter { $0 != path }
        Settings.set(paths, forKey: key)
        notify()
    }

    static func clear() {
        Settings.set([String](), forKey: key)
        notify()
    }

    static func contains(_ url: URL) -> Bool {
        (Settings.stringArray(forKey: key) ?? []).contains(url.standardizedFileURL.path)
    }

    private static func notify() {
        NotificationCenter.default.post(name: .soquelShelfChanged, object: nil)
    }

    /// A one-line description for the status bar.
    static var summary: String {
        let count = self.count
        switch count {
        case 0: return "The shelf is empty"
        case 1: return "1 file on the shelf"
        default: return "\(count) files on the shelf"
        }
    }
}
