import Foundation

/// Application logging, to one dated file in `~/Library/Logs/Soquel/`.
///
/// One place, not two. The system log needs `log show` or Console.app to read
/// and cannot be pasted into an email; a text file can be opened, copied and
/// sent by anyone.
enum Log {
    enum Category: String, CaseIterable {
        case app
        case ui
        case files
        case search
        case scan
        case settings
        case remote
        case panes

    }

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    // MARK: - Where it goes

    /// `~/Library/Logs/Soquel/` — where macOS expects an application's logs,
    /// and where Console.app already looks.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SOQUEL_LOG_DIR"] {
            return URL(fileURLWithPath: override)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-test-logs-\(getpid())")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Soquel")
    }

    static func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("soquel-\(dayStamp.string(from: date)).log")
    }

    private static let dayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static let timeStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Writing

    private static let queue = DispatchQueue(label: "app.soquel.log", qos: .utility)
    private static let lock = NSLock()
    /// Recent entries, so "copy the last few minutes" needs no file read and
    /// works even if the disk write failed.
    private static var buffer: [(date: Date, line: String)] = []
    /// Roughly an hour of chatty use. Beyond this the file is the record.
    static let bufferLimit = 4000

    /// Whether DEBUG lines are recorded at all. Off unless asked for: they
    /// exist for development, and the ordinary levels are the record a bug
    /// report needs. Chatty debug lines were being formatted on the main
    /// thread on every redraw and keystroke in shipping builds.
    static var debugEnabled = ProcessInfo.processInfo.environment["SOQUEL_DEBUG_LOG"] != nil
        || NSClassFromString("XCTestCase") != nil

    static func write(
        _ level: Level, _ category: Category, _ message: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        // Only the message closure runs on the caller's thread — it can
        // capture UI state, which must be read where it lives. The date
        // formatting and string assembly happen on the log's own queue, off
        // whatever thread the caller is busy on.
        let text = message()
        let now = Date()
        let origin = (file as NSString).lastPathComponent

        queue.async {
            let entry = "\(timeStamp.string(from: now)) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) "
                + "[\(category.rawValue)] \(text)  (\(origin):\(line))"

            lock.lock()
            buffer.append((now, entry))
            if buffer.count > bufferLimit { buffer.removeFirst(buffer.count - bufferLimit) }
            lock.unlock()

            append(entry, at: now)
        }
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) {
        guard debugEnabled else { return }
        write(.debug, category, message(), file: file, line: line)
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) {
        write(.info, category, message(), file: file, line: line)
    }

    static func warn(_ category: Category, _ message: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) {
        write(.warn, category, message(), file: file, line: line)
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) {
        write(.error, category, message(), file: file, line: line)
    }

    private static func append(_ entry: String, at date: Date) {
        let url = fileURL(for: date)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = (entry + "\n").data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Reading back

    /// The last `minutes` of entries, newest last, with a header describing the
    /// machine — the thing a bug report needs and nobody remembers to include.
    static func recent(minutes: Double = 3) -> String {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        // Entries are assembled on the log queue; readers wait for what is
        // already in flight so a report never misses the line that caused it.
        queue.sync {}
        lock.lock()
        let entries = buffer.filter { $0.date >= cutoff }.map(\.line)
        lock.unlock()

        var report = [header(minutes: minutes, count: entries.count)]
        report.append(contentsOf: entries.isEmpty ? ["(nothing logged in this window)"] : entries)
        return report.joined(separator: "\n")
    }

    static func header(minutes: Double, count: Int) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        Soquel \(version) (\(build)) · \(os)
        Last \(Int(minutes)) minutes · \(count) entries · logs in \(directory.path)
        ────────────────────────────────────────────────────────────
        """
    }

    /// Everything held in memory, for the log window.
    static var everything: [String] {
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        return buffer.map(\.line)
    }

    static func clearBuffer() {
        queue.sync {}
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    // MARK: - Tidying up

    /// How long a log file is kept. A day of logs is enough to describe a bug
    /// that happened this morning; a month of them is just disk.
    static let retention: TimeInterval = 24 * 60 * 60

    /// Deletes log files last written more than `retention` ago. Returns how
    /// many went, so a test can check it did something.
    @discardableResult
    static func removeOldFiles(now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        var removed = 0
        // By name, not by URL: the same directory reached through /var and
        // /private/var gives two URLs that compare unequal.
        let today = fileURL(for: now).lastPathComponent
        for file in files where file.pathExtension == "log" {
            // Never the file being written to right now, whatever its stamp.
            guard file.lastPathComponent != today else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > retention {
                try? manager.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }

    /// Called at launch and once a day after, so a long-running window still
    /// tidies up behind itself.
    static func startHousekeeping() {
        removeOldFiles()
        Timer.scheduledTimer(withTimeInterval: retention, repeats: true) { _ in
            let removed = removeOldFiles()
            if removed > 0 { info(.app, "Removed \(removed) log file(s) older than 24 hours") }
        }
    }
}
