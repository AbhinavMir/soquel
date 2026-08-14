import Foundation

extension Notification.Name {
    static let soquelSettingsChanged = Notification.Name("app.soquel.settingsChanged")
}

/// Every setting lives in one JSON file that a person can read and edit, rather
/// than in the defaults database where it is invisible without `defaults read`.
///
/// The file is the store, not a copy of one: reads come from it and writes go
/// to it. Editing it by hand while the app is running is supported — the
/// directory is watched, and an outside change reloads and redraws.
final class SettingsStore {
    static let shared = SettingsStore(url: defaultURL)

    /// `~/Library/Application Support/Soquel/settings.json`, beside theme.json.
    ///
    /// Tests get their own file: they mutate settings freely, and must not
    /// rewrite the settings of whoever is running them.
    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOQUEL_SETTINGS_PATH"] {
            return URL(fileURLWithPath: override)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-test-settings-\(getpid()).json")
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soquel/settings.json")
    }

    let url: URL
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    /// Guards the two watcher sources. Separate from `lock`, which guards the
    /// values: a watcher's handler reads the values, so one lock for both
    /// would have the handler waiting on the thread that is replacing it.
    private let watcherLock = NSLock()
    private var watcher: DispatchSourceFileSystemObject?
    /// A second source on the file itself. The directory only reports entries
    /// appearing and disappearing, so an editor that saves in place — writing
    /// through the existing inode rather than swapping in a new file — makes
    /// no directory event at all.
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// What we last wrote, so our own writes do not look like outside edits.
    private var lastWritten: Data?
    private var writeScheduled = false
    /// Bumped by every change to `values`, and caught up to by the writer only
    /// once a write has landed. The two differing means the file is behind
    /// memory — a change made while a write was in flight, or a write that
    /// failed — and the file must then not be read back over memory.
    private var changeCount = 0
    private var writtenChangeCount = 0
    /// Whether the last write failed. Kept so the debounce does not retry a
    /// write that cannot succeed, every quarter second, for the rest of the run.
    private var lastWriteFailed = false
    /// When we last wrote. An atomic write is a create followed by a rename,
    /// and the watcher sees both — on the first of them the file may still
    /// hold the previous contents.
    private var lastWriteTime: Date?
    /// How long after our own write an outside change is disbelieved.
    static let settlingWindow: TimeInterval = 1.0

    init(url: URL) {
        self.url = url
        load()
    }

    // MARK: - Reading

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func double(forKey key: String) -> Double? { object(forKey: key) as? Double }
    func integer(forKey key: String) -> Int? { object(forKey: key) as? Int }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }

    /// Codable values are stored as real nested JSON, not as a base64 blob, so
    /// the file stays editable all the way down.
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let raw = object(forKey: key),
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Writing

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value, JSONSerialization.isValidJSONObject([value]) {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        changeCount += 1
        lock.unlock()
        scheduleWrite()
    }

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else { return }
        set(raw, forKey: key)
    }

    func removeObject(forKey key: String) { set(nil, forKey: key) }

    /// Every key currently set, for the settings window and for tests.
    var allKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }

    /// Whether memory holds values the file does not, for the tests: no change
    /// may be left with neither a write done nor a write pending.
    var hasUnwrittenChanges: Bool {
        lock.lock(); defer { lock.unlock() }
        return changeCount != writtenChangeCount
    }

    // MARK: - Disk

    private func load() {
        // A missing file is a first launch; nothing to do.
        guard let data = try? Data(contentsOf: url) else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The file exists but does not parse — usually a hand edit gone
            // wrong. It is put aside, not read over: with the store empty, the
            // next write (quit at the latest) would replace the file with
            // nothing and every setting would be gone. This way the app runs
            // on defaults and the broken original survives beside it.
            let backup = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.error(.settings,
                "settings.json did not parse; kept as \(backup.lastPathComponent), starting from defaults")
            return
        }
        lock.lock()
        values = parsed
        lock.unlock()
    }

    /// Writes coalesce: navigating a folder rewrites the session keys, and that
    /// should not mean a file write per keystroke.
    private func scheduleWrite() {
        lock.lock()
        let alreadyScheduled = writeScheduled
        writeScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        armWriteTimer()
    }

    private func armWriteTimer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.writeNow()
            self.finishScheduledWrite()
        }
    }

    /// Ends a debounced pass, and arms another if memory has moved on since the
    /// write took its snapshot.
    ///
    /// The flag is cleared after the write, not before: while it is set the
    /// watcher knows memory is ahead of the file. It used to be cleared
    /// unconditionally, which stranded any set() landing between the snapshot
    /// and here — such a set() finds the flag still set and so arms no timer of
    /// its own, and was then left without one: the value stayed in memory only,
    /// lost at quit, and meanwhile the older file no longer looked pending and
    /// could be read back over it.
    func finishScheduledWrite() {
        lock.lock()
        // Both read and written under one hold, so a set() either bumps the
        // count before the check or finds the flag already cleared and arms its
        // own timer. Splitting them would let one slip between the two.
        let pending = changeCount != writtenChangeCount && !lastWriteFailed
        writeScheduled = pending
        lock.unlock()
        if pending { armWriteTimer() }
    }

    func writeNow() {
        lock.lock()
        let snapshot = values
        // Taken with the snapshot, not at the end: a set() arriving while the
        // write is in flight leaves changeCount ahead of it, which is how the
        // debounce knows that another pass is owed.
        let snapshotCount = changeCount
        // Stamped before the write rather than after it: an atomic save is a
        // create plus a rename, and the watcher can read the file while that is
        // still in flight, so the settling window has to already cover it.
        lastWriteTime = Date()
        lock.unlock()

        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            noteWriteFailed("settings could not be encoded as JSON; not written")
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            lock.lock()
            lastWritten = data
            writtenChangeCount = snapshotCount
            lastWriteFailed = false
            lock.unlock()
        } catch {
            // lastWritten keeps the bytes that did reach the file. It used to
            // be set to these ones before the write was even attempted, and the
            // write itself was a `try?` — so an unwritable Application Support,
            // a full disk or a sandbox denial left the store believing the file
            // held values it had never received. The next watcher event read
            // the old file, found it different from what we thought we had
            // written, took it for someone else's edit and adopted it: every
            // setting the user had just changed reverted, with nothing said
            // anywhere. A directory event from theme.json is enough to set that
            // off, so it did not even need the user to touch settings.json.
            noteWriteFailed("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private func noteWriteFailed(_ reason: String) {
        lock.lock()
        lastWriteFailed = true
        lock.unlock()
        Log.error(.settings, reason)
    }

    /// Watches the containing directory rather than the file: an atomic save
    /// from a text editor replaces the file, and a file handle would be left
    /// pointing at the old inode.
    func startWatching() {
        watcherLock.lock()
        let already = watcher != nil
        watcherLock.unlock()
        guard !already else { return }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An atomic save replaces the file, so the old inode is gone and
            // the file source has to be pointed at the new one.
            self.watchFile()
            self.reloadIfChangedOutside()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcherLock.lock()
        let displaced = watcher
        watcher = source
        watcherLock.unlock()
        displaced?.cancel()
        watchFile()
    }

    /// Watches the settings file itself, for saves that write in place.
    ///
    /// Called from two threads: `startWatching` on main, and the directory
    /// source's handler on a utility queue. Unsynchronised, both could build a
    /// source and assign, and the loser was released without ever being
    /// cancelled — which libdispatch treats as fatal — leaking its descriptor.
    /// Swapping under a lock means whichever assignment happens second cancels
    /// the one it displaces, so no live source is ever dropped.
    private func watchFile() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file is gone; the watcher pointing at it is no use either.
            watcherLock.lock()
            let orphan = fileWatcher
            fileWatcher = nil
            watcherLock.unlock()
            orphan?.cancel()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.reloadIfChangedOutside() }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watcherLock.lock()
        let displaced = fileWatcher
        fileWatcher = source
        watcherLock.unlock()
        // Outside the lock: cancel runs the handler that closes the descriptor.
        displaced?.cancel()
    }

    /// Whether a change on disk is really someone else's.
    ///
    /// Four ways it is not, and taking any of them for an outside edit means
    /// overwriting what the user just did with what the file used to say:
    ///
    /// - the bytes are exactly what we last wrote;
    /// - a write is still pending, so memory is ahead of the file by design;
    /// - a change has not reached the file at all, because it landed while a
    ///   write was in flight or because the write failed;
    /// - the write only just happened, and an atomic save is a create plus a
    ///   rename, so the watcher can read the file between the two.
    func shouldAdopt(_ data: Data, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let lastWritten, data == lastWritten { return false }
        if writeScheduled { return false }
        if changeCount != writtenChangeCount { return false }
        if let lastWriteTime, now.timeIntervalSince(lastWriteTime) < Self.settlingWindow { return false }
        return true
    }

    private func reloadIfChangedOutside() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard shouldAdopt(data) else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock()
        values = parsed
        lock.unlock()
        DispatchQueue.main.async {
            Log.info(.settings, "settings.json changed outside the app; reloaded")
            NotificationCenter.default.post(name: .soquelSettingsChanged, object: nil)
        }
    }

    /// Copies anything already in the defaults database into the file, once, so
    /// upgrading does not silently reset the app.
    func migrateFromUserDefaults(_ defaults: UserDefaults, keys: [String]) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var found = false
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            // Data-backed keys were Codable blobs; they are re-encoded as JSON
            // by whichever property next writes them.
            if value is Data { continue }
            lock.lock()
            if JSONSerialization.isValidJSONObject([value]) {
                values[key] = value
                changeCount += 1
                found = true
            }
            lock.unlock()
        }
        if found { writeNow() }
    }
}

/// Short name used at the call sites, which read like defaults access.
let Settings = SettingsStore.shared
