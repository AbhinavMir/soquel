import Foundation

extension Notification.Name {
    static let soquelRecentsChanged = Notification.Name("app.soquel.recentsChanged")
}

/// What you have just done, and what you have just touched.
///
/// The rule this is built to is that recording must never be felt. Nothing
/// here runs on the main thread beyond appending to an array behind a lock,
/// no index is kept, no folder is watched, and nothing is written to disk per
/// event: the file is rewritten on a timer and at quit, once, the way the log
/// already works. A history that costs a millisecond per keystroke is worse
/// than no history.
enum Recents {
    /// One thing that happened. Deliberately small — a kind, a path or two,
    /// and when — so a thousand of them are a few tens of kilobytes.
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable {
            case opened, copied, moved, renamed, trashed, deleted, created, compressed, extracted

            var verb: String {
                switch self {
                case .opened: return "Opened"
                case .copied: return "Copied"
                case .moved: return "Moved"
                case .renamed: return "Renamed"
                case .trashed: return "Trashed"
                case .deleted: return "Deleted"
                case .created: return "Created"
                case .compressed: return "Compressed"
                case .extracted: return "Extracted"
                }
            }
        }

        let kind: Kind
        let path: String
        /// Where it went, for a move, a copy or a rename.
        let destination: String?
        let at: Date
        /// How many items the action covered, when it was more than this one.
        let count: Int

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }

        var summary: String {
            let subject = count > 1 ? "\(name) and \(count - 1) more" : name
            guard let destination else { return "\(kind.verb) \(subject)" }
            let target = URL(fileURLWithPath: destination).lastPathComponent
            return "\(kind.verb) \(subject) → \(target)"
        }
    }

    /// Beyond this the oldest are dropped. Roughly a week of heavy use, and
    /// small enough that the whole list is written in one go without being
    /// noticed.
    static let limit = 2000

    private static let lock = NSLock()
    private static var entries: [Entry] = load()
    /// Set when the list has changed since the last write, so a quit with
    /// nothing new does no work.
    private static var dirty = false
    private static let queue = DispatchQueue(label: "app.soquel.recents", qos: .utility)

    // MARK: - Recording

    /// Records an action. Called from wherever the action actually happened,
    /// including a background queue: the append takes a lock and returns, and
    /// the write is somebody else's problem.
    static func record(_ kind: Entry.Kind, _ url: URL, to destination: URL? = nil, count: Int = 1) {
        let entry = Entry(kind: kind, path: url.path, destination: destination?.path,
                          at: Date(), count: count)
        lock.lock()
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        dirty = true
        lock.unlock()
        scheduleFlush()
    }

    /// Records one action covering many files, which is what a transfer is.
    static func record(_ kind: Entry.Kind, _ urls: [URL], to destination: URL? = nil) {
        guard let first = urls.first else { return }
        record(kind, first, to: destination, count: urls.count)
    }

    // MARK: - Reading

    /// Newest first.
    static var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.reversed()
    }

    /// The files touched most recently, one entry per file, newest first.
    /// A file opened five times is one row, not five.
    static func files(limit max: Int = 200) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for entry in all where !seen.contains(entry.path) {
            seen.insert(entry.path)
            result.append(entry)
            if result.count >= max { break }
        }
        return result
    }

    static func clear() {
        lock.lock()
        entries.removeAll()
        dirty = true
        lock.unlock()
        write()
        NotificationCenter.default.post(name: .soquelRecentsChanged, object: nil)
    }

    // MARK: - Disk

    static var fileURL: URL {
        ThemeConfig.directoryURL.appendingPathComponent("recents.json")
    }

    private static var flushScheduled = false

    /// One write every thirty seconds at most, however many actions happened
    /// in between.
    private static func scheduleFlush() {
        lock.lock()
        let already = flushScheduled
        flushScheduled = true
        lock.unlock()
        guard !already else { return }

        queue.asyncAfter(deadline: .now() + 30) {
            lock.lock()
            flushScheduled = false
            lock.unlock()
            write()
        }
    }

    /// Called at quit as well, so the last half minute is not lost.
    static func write() {
        lock.lock()
        let needed = dirty
        let snapshot = entries
        dirty = false
        lock.unlock()
        guard needed else { return }

        try? FileManager.default.createDirectory(
            at: ThemeConfig.directoryURL, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.app, "could not write recents.json: \(error.localizedDescription)")
        }
    }

    private static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A history is not worth keeping a broken file for: an unreadable one
        // starts empty rather than being put aside, since nothing is lost that
        // the filesystem does not still have.
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
