import Foundation

/// One queued file transfer, with enough state to show progress, pause it, and
/// pick it back up.
///
/// Finder's copy sheet reports a bar and nothing else: no throughput, no way to
/// pause, and a single unreadable file aborts the whole job. This is the model
/// behind not doing that.
final class TransferJob {
    enum State: String {
        case waiting, running, paused, finished, failed, cancelled

        var title: String {
            switch self {
            case .waiting: return "Waiting"
            case .running: return "Copying"
            case .paused: return "Paused"
            case .finished: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    let id = UUID()
    let sources: [URL]
    let destination: URL
    let isMove: Bool
    let createdAt: Date

    private(set) var state: State = .waiting
    private(set) var bytesCopied: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var filesCopied = 0
    private(set) var totalFiles = 0
    private(set) var currentFile: String?
    private(set) var failures: [(url: URL, message: String)] = []
    private(set) var startedAt: Date?

    /// Bytes per second over the life of the job, once enough has moved to mean
    /// anything.
    private(set) var bytesPerSecond: Double = 0

    /// The file named by the most recent `recordFailure`, cleared by the next
    /// `advance`. The copy loop reports a failure by recording it and then
    /// calling `advance` with zero bytes, so that the panel keeps naming the
    /// file it was working on. `advance` used to count every named file as
    /// copied, which meant a job where all ten files failed still summarised
    /// itself as "10 of 10 failed — 10 copied": a reading a user could act on
    /// by deleting sources that never arrived.
    private var justFailedFile: String?

    init(sources: [URL], destination: URL, isMove: Bool, now: Date) {
        self.sources = sources
        self.destination = destination
        self.isMove = isMove
        self.createdAt = now
    }

    var title: String {
        let verb = isMove ? "Move" : "Copy"
        let what = sources.count == 1
            ? sources[0].lastPathComponent
            : "\(sources.count) items"
        return "\(verb) \(what) → \(destination.lastPathComponent)"
    }

    var fractionComplete: Double {
        guard totalBytes > 0 else { return state == .finished ? 1 : 0 }
        return min(1, Double(bytesCopied) / Double(totalBytes))
    }

    /// Seconds remaining, or nil when there is not enough information to say.
    /// A guess presented as a number is worse than no number.
    var secondsRemaining: Double? {
        guard state == .running, bytesPerSecond > 1, totalBytes > 0 else { return nil }
        let left = Double(totalBytes - bytesCopied)
        guard left > 0 else { return nil }
        return left / bytesPerSecond
    }

    var isActive: Bool { state == .running || state == .paused || state == .waiting }

    // MARK: - Transitions

    func markStarted(totalBytes: Int64, totalFiles: Int, now: Date) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        startedAt = now
        state = .running
    }

    func advance(bytes: Int64, file: String?, now: Date) {
        bytesCopied += bytes
        // A named file counts as copied unless this is the zero-byte report of
        // the failure just recorded against that same name. Matching on both
        // the pending failure and the name keeps a later file that happens to
        // share a name with a failed one from being lost from the count.
        if let file, file != justFailedFile { filesCopied += 1 }
        justFailedFile = nil
        currentFile = file
        if let startedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed > 0.25 { bytesPerSecond = Double(bytesCopied) / elapsed }
        }
    }

    /// A file that could not be copied is recorded and the job carries on. One
    /// unreadable file must not abandon the other nine hundred.
    func recordFailure(_ url: URL, _ message: String) {
        failures.append((url, message))
        justFailedFile = url.lastPathComponent
    }

    private(set) var manifest: VerifiedCopy.Manifest?

    func recordVerification(_ manifest: VerifiedCopy.Manifest) {
        self.manifest = manifest
        // A copy whose bytes did not survive is not a finished job.
        for entry in manifest.failed {
            failures.append((entry.destination, "Checksum did not match after copying"))
        }
    }

    func pause() { if state == .running { state = .paused } }
    func resume() { if state == .paused { state = .running } }
    func cancel() { if isActive { state = .cancelled } }

    func finish() {
        guard state != .cancelled else { return }
        state = failures.isEmpty ? .finished : .failed
        currentFile = nil
    }

    /// What the row says: never a bare percentage, always what is happening.
    func statusLine(formatter: ByteCountFormatter) -> String {
        switch state {
        case .waiting:
            return "Waiting"
        case .paused:
            return "Paused — \(formatter.string(fromByteCount: bytesCopied)) of \(formatter.string(fromByteCount: totalBytes))"
        case .cancelled:
            return "Cancelled after \(formatter.string(fromByteCount: bytesCopied))"
        case .finished:
            return "\(filesCopied) file\(filesCopied == 1 ? "" : "s"), \(formatter.string(fromByteCount: bytesCopied))"
        case .failed:
            return "\(failures.count) of \(totalFiles) failed — \(filesCopied) copied"
        case .running:
            var text = "\(formatter.string(fromByteCount: bytesCopied)) of \(formatter.string(fromByteCount: totalBytes))"
            if bytesPerSecond > 1 {
                text += " · \(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
            }
            if let remaining = secondsRemaining {
                text += " · \(Self.describe(seconds: remaining)) left"
            }
            if let currentFile { text += " · \(currentFile)" }
            return text
        }
    }

    /// Coarse on purpose. A second-by-second countdown that jitters is worse
    /// than a rounded one that holds still.
    static func describe(seconds: Double) -> String {
        switch seconds {
        case ..<10: return "a few seconds"
        case ..<60: return "\(Int(seconds / 10) * 10) seconds"
        case ..<3600:
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        default:
            let hours = seconds / 3600
            return String(format: "%.1f hours", hours)
        }
    }
}

/// Everything queued, running, and recently finished.
final class TransferQueue {
    static let shared = TransferQueue()

    private(set) var jobs: [TransferJob] = []

    /// Posted whenever a job is added or changes, so a panel can redraw.
    static let changed = Notification.Name("app.soquel.transferQueueChanged")

    var activeCount: Int { jobs.filter(\.isActive).count }

    func add(_ job: TransferJob) {
        jobs.append(job)
        notify()
    }

    func job(id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// Moves a waiting job. Only waiting jobs can be reordered: a running one
    /// is already moving bytes, and putting it later in a list does not
    /// un-start it.
    @discardableResult
    func move(id: UUID, to index: Int) -> Bool {
        guard let from = jobs.firstIndex(where: { $0.id == id }), jobs[from].state == .waiting else {
            return false
        }
        let target = TransferQueue.clampedDestination(from: from, to: index, count: jobs.count)
        guard target != from else { return false }
        let job = jobs.remove(at: from)
        jobs.insert(job, at: target)
        notify()
        return true
    }

    /// Where a drag from `from` to `to` actually lands, accounting for the row
    /// being lifted out before it is put back.
    static func clampedDestination(from: Int, to: Int, count: Int) -> Int {
        let adjusted = to > from ? to - 1 : to
        return max(0, min(adjusted, count - 1))
    }

    /// Puts a job's failed files back on the queue as a fresh job.
    ///
    /// A new job rather than resurrecting the old one: the old one is a record
    /// of what happened, and rewriting it to say it succeeded loses that.
    @discardableResult
    func retryFailures(of job: TransferJob) -> [URL] {
        let urls = job.failures.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return [] }
        OperationEngine.shared.transfer(
            urls, to: job.destination, move: job.isMove,
            resolveConflict: { _, _ in ConflictResolution(choice: .keepBoth) },
            completion: { _ in }
        )
        return urls
    }

    func notify() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Clears everything that is no longer running. Active jobs are kept: the
    /// button is "clear finished", not "cancel everything".
    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        notify()
    }

    func cancelAll() {
        for job in jobs where job.isActive { job.cancel() }
        notify()
    }

    /// Total bytes across every file under the given roots, for a progress bar
    /// that means something. Counted before the copy starts.
    static func measure(_ urls: [URL]) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]

        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                bytes += Int64(values?.fileSize ?? 0)
                files += 1
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: []
            ) else { continue }
            for case let child as URL in enumerator {
                guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
                guard childValues.isSymbolicLink != true, childValues.isRegularFile == true else { continue }
                bytes += Int64(childValues.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, files)
    }
}
