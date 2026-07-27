import Accelerate
import Foundation
import NaturalLanguage

extension Notification.Name {
    static let soquelIndexChanged = Notification.Name("app.soquel.indexChanged")
}

/// Search by meaning rather than by the letters you typed.
///
/// Every readable file is split into passages, each passage turned into a
/// vector by the sentence embedding macOS already ships, and the vectors kept
/// in one file. A query becomes a vector the same way, and the answer is
/// whichever passages point in the same direction.
///
/// The model is Apple's, on this machine, with no download and no request. An
/// index that needed a server would make the application's one real claim —
/// that it never talks to anything — false.
///
/// Vectors are stored beside the index, not in each file's extended attributes.
/// Writing two kilobytes onto every document someone owns changes their files
/// to serve a feature of ours, and the attributes do not survive most copies
/// anyway.
final class SemanticIndex {
    static let shared = SemanticIndex()

    /// Apple's sentence embedding: 512 dimensions, English.
    static let dimensions = 512

    /// One passage of one file, and where it came from.
    struct Entry: Codable {
        var path: String
        /// Byte offset is not kept; the passage itself is, so a result can be
        /// shown without opening the file again.
        var passage: String
        var vector: [Float]
    }

    /// What was known about a file when it was last read, so unchanged files
    /// are not read again.
    struct FileStamp: Codable, Equatable {
        var modified: Double
        var size: Int64
    }

    struct Stored: Codable {
        var entries: [Entry]
        var stamps: [String: FileStamp]
    }

    struct Hit {
        let url: URL
        let passage: String
        /// Cosine similarity, 0 to 1. Higher is closer.
        let score: Float
    }

    struct Progress {
        let filesSeen: Int
        let filesIndexed: Int
        let currentPath: String
    }

    private let queue = DispatchQueue(label: "app.soquel.semantic", qos: .utility)
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var stamps: [String: FileStamp] = [:]
    /// Every vector laid end to end, for one pass of arithmetic rather than a
    /// loop over arrays of arrays.
    private var flat: [Float] = []
    private var cancelled = false
    private(set) var isIndexing = false

    private init() { load() }

    // MARK: - Where it lives

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOQUEL_INDEX_PATH"] {
            return URL(fileURLWithPath: override)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-test-index-\(getpid()).json")
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soquel/semantic-index.json")
    }

    /// Folders the user has asked to be indexed.
    static var roots: [URL] {
        get { (Settings.stringArray(forKey: "semanticRoots") ?? []).map { URL(fileURLWithPath: $0) } }
        set { Settings.set(newValue.map(\.path), forKey: "semanticRoots") }
    }

    static func addRoot(_ url: URL) {
        var current = roots.map(\.standardizedFileURL.path)
        let path = url.standardizedFileURL.path
        guard !current.contains(path) else { return }
        current.append(path)
        Settings.set(current, forKey: "semanticRoots")
    }

    static func removeRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        Settings.set(roots.map(\.path).filter { $0 != path }, forKey: "semanticRoots")
    }

    // MARK: - The model

    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    static var isAvailable: Bool { embedding != nil }

    /// A unit-length vector for a piece of text, or nil when the model has
    /// nothing to say about it.
    static func vector(for text: String) -> [Float]? {
        guard let embedding, let raw = embedding.vector(for: text) else { return nil }
        var v = raw.map(Float.init)
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        // Normalised once, here, so comparing two of them is a dot product
        // rather than a cosine with two square roots in it.
        var scale = 1 / norm
        vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
        return v
    }

    // MARK: - Searching

    var entryCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var fileCount: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }

    /// The closest passages to `text`.
    ///
    /// `within` narrows to one folder, which is what makes this local as well
    /// as global; nil searches everything indexed.
    func search(_ text: String, within folder: URL? = nil, limit: Int = 40, minimumScore: Float = 0.25) -> [Hit] {
        guard let query = Self.vector(for: text) else { return [] }
        lock.lock()
        let entries = self.entries
        let flat = self.flat
        lock.unlock()
        guard !entries.isEmpty else { return [] }

        // One matrix-vector multiply for every passage at once. The vectors are
        // already unit length, so the product is the cosine.
        var scores = [Float](repeating: 0, count: entries.count)
        let d = Self.dimensions
        flat.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                cblas_sgemv(CblasRowMajor, CblasNoTrans,
                            Int32(entries.count), Int32(d), 1,
                            m.baseAddress, Int32(d),
                            q.baseAddress, 1, 0, &scores, 1)
            }
        }

        let prefix = folder?.standardizedFileURL.path
        var hits: [Hit] = []
        var bestPerFile: [String: Int] = [:]

        for (index, score) in scores.enumerated() where score >= minimumScore {
            let entry = entries[index]
            if let prefix, !entry.path.hasPrefix(prefix) { continue }
            // One result per file: five passages from the same document push
            // everything else off the list.
            if let seen = bestPerFile[entry.path], scores[seen] >= score { continue }
            bestPerFile[entry.path] = index
        }
        for index in bestPerFile.values {
            let entry = entries[index]
            hits.append(Hit(url: URL(fileURLWithPath: entry.path),
                            passage: entry.passage, score: scores[index]))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Building

    func cancel() { cancelled = true }

    /// Reads every readable file under the indexed roots that has changed, and
    /// leaves the rest alone.
    func rebuild(
        roots: [URL] = SemanticIndex.roots,
        progress: @escaping (Progress) -> Void,
        finished: @escaping (Int) -> Void
    ) {
        guard Self.isAvailable else { finished(0); return }
        guard !isIndexing else { return }
        isIndexing = true
        cancelled = false

        queue.async { [weak self] in
            guard let self else { return }
            var seen = 0, indexed = 0
            var freshStamps: [String: FileStamp] = [:]
            var kept: [Entry] = []
            var added: [Entry] = []

            self.lock.lock()
            let oldStamps = self.stamps
            let oldEntries = self.entries
            self.lock.unlock()

            var live = Set<String>()
            for root in roots {
                guard let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                                           .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in walker {
                    if self.cancelled { break }
                    guard TextExtraction.canRead(url) else { continue }
                    seen += 1
                    let path = url.standardizedFileURL.path
                    live.insert(path)

                    let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let stamp = FileStamp(
                        modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        size: Int64(values?.fileSize ?? 0)
                    )
                    freshStamps[path] = stamp

                    // Unchanged since last time: keep what was already computed.
                    if oldStamps[path] == stamp {
                        kept.append(contentsOf: oldEntries.filter { $0.path == path })
                        continue
                    }

                    guard let text = TextExtraction.text(of: url) else { continue }
                    for passage in TextExtraction.passages(text) {
                        guard let vector = Self.vector(for: passage) else { continue }
                        added.append(Entry(path: path, passage: passage, vector: vector))
                    }
                    indexed += 1
                    if indexed % 20 == 0 {
                        let snapshot = Progress(filesSeen: seen, filesIndexed: indexed, currentPath: path)
                        DispatchQueue.main.async { progress(snapshot) }
                    }
                }
            }

            // Files that have gone take their passages with them.
            let surviving = kept.filter { live.contains($0.path) }
            let all = surviving + added

            self.lock.lock()
            self.entries = all
            self.stamps = freshStamps
            self.rebuildFlat()
            self.lock.unlock()
            self.save()

            DispatchQueue.main.async {
                self.isIndexing = false
                NotificationCenter.default.post(name: .soquelIndexChanged, object: nil)
                Log.info(.search, "Semantic index: \(all.count) passages across \(freshStamps.count) files")
                finished(all.count)
            }
        }
    }

    func clear() {
        lock.lock()
        entries = []
        stamps = [:]
        flat = []
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.fileURL)
        NotificationCenter.default.post(name: .soquelIndexChanged, object: nil)
    }

    /// Must be called with the lock held.
    private func rebuildFlat() {
        flat = [Float](repeating: 0, count: entries.count * Self.dimensions)
        for (row, entry) in entries.enumerated() {
            guard entry.vector.count == Self.dimensions else { continue }
            flat.replaceSubrange(row * Self.dimensions ..< (row + 1) * Self.dimensions,
                                 with: entry.vector)
        }
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        lock.lock()
        entries = stored.entries
        stamps = stored.stamps
        rebuildFlat()
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let stored = Stored(entries: entries, stamps: stamps)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
