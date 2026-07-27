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
    private var watcher: DispatchSourceFileSystemObject?
    /// A second source on the file itself. The directory only reports entries
    /// appearing and disappearing, so an editor that saves in place — writing
    /// through the existing inode rather than swapping in a new file — makes
    /// no directory event at all.
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// What we last wrote, so our own writes do not look like outside edits.
    private var lastWritten: Data?
    private var writeScheduled = false
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

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            // Cleared after the write, not before: while it is set the watcher
            // knows memory is ahead of the file.
            self.writeNow()
            self.lock.lock()
            self.writeScheduled = false
            self.lock.unlock()
        }
    }

    func writeNow() {
        lock.lock()
        let snapshot = values
        lock.unlock()
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        lock.lock()
        lastWritten = data
        lastWriteTime = Date()
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Watches the containing directory rather than the file: an atomic save
    /// from a text editor replaces the file, and a file handle would be left
    /// pointing at the old inode.
    func startWatching() {
        guard watcher == nil else { return }
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
        watcher = source
        watchFile()
    }

    /// Watches the settings file itself, for saves that write in place.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.reloadIfChangedOutside() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatcher = source
    }

    /// Whether a change on disk is really someone else's.
    ///
    /// Three ways it is ours, and taking any of them for an outside edit means
    /// overwriting what the user just did with what the file used to say:
    ///
    /// - the bytes are exactly what we last wrote;
    /// - a write is still pending, so memory is ahead of the file by design;
    /// - the write only just happened, and an atomic save is a create plus a
    ///   rename, so the watcher can read the file between the two.
    func shouldAdopt(_ data: Data, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let lastWritten, data == lastWritten { return false }
        if writeScheduled { return false }
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
                found = true
            }
            lock.unlock()
        }
        if found { writeNow() }
    }
}

/// Short name used at the call sites, which read like defaults access.
let Settings = SettingsStore.shared
