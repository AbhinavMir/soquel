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

    /// How many passages are embedded at once.
    ///
    /// One model instance per worker. Sharing a single instance across threads
    /// deadlocks — measured, four hundred concurrent calls never returned —
    /// but a model each runs 3.6 times faster than one thread on this machine.
    static var workerCount: Int {
        max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Embeds many passages at once, each worker holding its own model.
    static func vectors(for passages: [String]) -> [[Float]?] {
        guard passages.count > 8 else { return passages.map { vector(for: $0) } }

        var result = [[Float]?](repeating: nil, count: passages.count)
        let lock = NSLock()
        let workers = workerCount
        let group = DispatchGroup()

        for worker in 0..<workers {
            DispatchQueue.global(qos: .utility).async(group: group) {
                guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return }
                var index = worker
                while index < passages.count {
                    let vector = normalised(model.vector(for: passages[index]))
                    lock.lock(); result[index] = vector; lock.unlock()
                    index += workers
                }
            }
        }
        group.wait()
        return result
    }

    /// Scales a raw vector to unit length, so comparing two is a dot product
    /// rather than a cosine with two square roots in it.
    private static func normalised(_ raw: [Double]?) -> [Float]? {
        guard let raw else { return nil }
        var v = raw.map(Float.init)
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        var scale = 1 / norm
        vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
        return v
    }

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
    /// A rebuild asked for while one is running. The running pass read its
    /// roots before the new request existed, so dropping the request would
    /// leave a freshly added folder unindexed with no error and a status bar
    /// that reports success. The request is kept and started when the current
    /// pass lands. The newest request decides what is walked — its roots are
    /// stored as given, nil meaning the settings list read afresh at replay —
    /// and every superseded request's finished closure still fires with the
    /// replay's count, so no caller waits forever.
    private var queuedRebuild: (roots: [URL]?, progress: (Progress) -> Void, finished: (Int) -> Void)?

    private init() {
        // Off the main thread. This runs on whoever first touches `shared`,
        // which is the window controller during launch, and the file is one
        // JSON document holding 512 floats per passage — a large index is
        // hundreds of megabytes to read and parse before the window appears.
        //
        // Searching before the load lands returns nothing rather than
        // blocking; the index posts soquelIndexChanged when it is ready.
        //
        // Tests want it loaded before they look, so they take the wait.
        if NSClassFromString("XCTestCase") != nil {
            load()
        } else {
            queue.async { [weak self] in
                self?.load()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .soquelIndexChanged, object: nil)
                }
            }
        }
    }

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

    /// Adds a folder to the index, keeping the roots non-overlapping.
    ///
    /// A folder already covered by a root adds nothing. A folder that contains
    /// existing roots replaces them, since it covers everything they did.
    /// Overlapping roots would walk the shared files once per root.
    static func addRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        let current = roots.map(\.standardizedFileURL.path)
        guard !current.contains(where: { self.path(path, isWithin: $0) }) else { return }
        var kept = current.filter { !self.path($0, isWithin: path) }
        kept.append(path)
        Settings.set(kept, forKey: "semanticRoots")
    }

    static func removeRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        Settings.set(roots.map(\.path).filter { $0 != path }, forKey: "semanticRoots")
    }

    // MARK: - The model

    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// The shared model deadlocks under concurrent use (see workerCount), and
    /// this instance is reached from both the indexing queue — small batches
    /// skip the per-worker models — and the main thread's search-as-you-type.
    private static let embeddingLock = NSLock()

    static var isAvailable: Bool { embedding != nil }

    /// A unit-length vector for a piece of text, or nil when the model has
    /// nothing to say about it.
    static func vector(for text: String) -> [Float]? {
        guard let embedding else { return nil }
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        return normalised(embedding.vector(for: text))
    }

    // MARK: - Searching

    var entryCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var fileCount: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }

    /// The closest passages to `text`.
    ///
    /// `within` narrows to one folder, which is what makes this local as well
    /// as global; nil searches everything indexed.
    /// How much of the score comes from the words themselves rather than from
    /// the meaning.
    ///
    /// Meaning alone ranks a vaguely-related document above one that says the
    /// exact thing, which reads as broken however good the reasoning behind it
    /// is. A quarter is enough to put a literal match on top without drowning
    /// out the part that makes this different from the contents search.
    static let literalWeight: Float = 0.25

    /// The alphanumeric words of a piece of text, lowercased.
    ///
    /// The query and the text being scored are cut on the same boundaries, so
    /// a term either is one of the words or is not there at all.
    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    }

    /// The words in a query, lowercased, with the ones too common to carry
    /// meaning dropped.
    static func terms(of text: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "of", "for", "in", "on", "to", "and",
                                 "or", "is", "are", "was", "were", "with", "from", "by",
                                 "at", "as", "it", "this", "that", "my", "our", "your"]
        return words(in: text).filter { $0.count > 2 && !stop.contains($0) }
    }

    /// Whether `path` is `folder` itself or something inside it.
    ///
    /// `hasPrefix` on the bare path is not this test: ~/Notes-archive/a.md
    /// starts with ~/Notes, so scoping a search to one folder returned hits
    /// from its similarly named sibling.
    static func path(_ path: String, isWithin folder: String) -> Bool {
        if path == folder { return true }
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(base)
    }

    /// What fraction of the query's words appear in this text, counting the
    /// file's own name — a file called berlin-revenue.txt is about Berlin
    /// revenue whatever its contents say.
    ///
    /// A word at a time, not a substring. `contains` scored a query of "car" a
    /// full 1.0 against a passage whose only mention was "scar" or "discard",
    /// and "art" against "start"; a quarter of a point of invented score is
    /// enough to lift such a passage above one that genuinely matches.
    static func literalScore(terms: [String], passage: String, path: String) -> Float {
        guard !terms.isEmpty else { return 0 }
        // The name is cut on the same boundaries, so berlin-revenue.txt offers
        // "berlin" and "revenue" as words of their own.
        var vocabulary = Set(words(in: passage))
        vocabulary.formUnion(words(in: (path as NSString).lastPathComponent))
        let hits = terms.filter { vocabulary.contains($0) }.count
        return Float(hits) / Float(terms.count)
    }

    func search(_ text: String, within folder: URL? = nil, limit: Int = 40, minimumScore: Float = 0.25) -> [Hit] {
        guard let query = Self.vector(for: text) else { return [] }
        // cblas_sgemv is told to read exactly `dimensions` floats from the
        // query, so a model of a different width would have it read past the
        // end — garbage scores, or a crash. rebuildFlat already drops stored
        // vectors that are the wrong length; this is the other half of it.
        guard query.count == Self.dimensions else {
            Log.error(.search, "sentence model is \(query.count)-dimensional, expected \(Self.dimensions)")
            return []
        }
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

        // Blend in the literal match, so a document that actually says the
        // words is not ranked below one that merely resembles them.
        let queryTerms = Self.terms(of: text)
        let semanticWeight = 1 - Self.literalWeight
        // Every entry is blended, not just the promising ones. Skipping the
        // weak ones left two scales in the same array: an unblended 0.050 beat
        // a blended 0.060, and a file whose name is the query — literal 1.0,
        // which alone clears the threshold — stayed at its low semantic score
        // and never surfaced.
        for index in scores.indices {
            let entry = entries[index]
            let literal = Self.literalScore(terms: queryTerms, passage: entry.passage, path: entry.path)
            scores[index] = scores[index] * semanticWeight + literal * Self.literalWeight
        }

        // Compared as a path, not as a string: "/Users/x/Notes" is a prefix of
        // "/Users/x/Notes-archive/a.md", which is a different folder.
        let prefix = folder?.standardizedFileURL.path
        var hits: [Hit] = []
        var bestPerFile: [String: Int] = [:]

        for (index, score) in scores.enumerated() where score >= minimumScore {
            let entry = entries[index]
            if let prefix, !Self.path(entry.path, isWithin: prefix) { continue }
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
    ///
    /// nil roots means the settings list, read when the pass actually starts.
    /// That timing matters for a request queued behind a running pass: it
    /// replays later, and a root added in the meantime must be walked.
    /// Explicit roots are honoured exactly, even when the request waits.
    func rebuild(
        roots: [URL]? = nil,
        progress: @escaping (Progress) -> Void,
        finished: @escaping (Int) -> Void
    ) {
        guard Self.isAvailable else { finished(0); return }
        guard !isIndexing else {
            // The newest request decides what the replay walks, but a
            // completion promise is never dropped: a superseded request's
            // finished closure fires alongside the replacement's.
            if let waiting = queuedRebuild {
                let waitingFinished = waiting.finished
                queuedRebuild = (roots, progress, { (count: Int) in
                    waitingFinished(count)
                    finished(count)
                })
            } else {
                queuedRebuild = (roots, progress, finished)
            }
            return
        }
        isIndexing = true
        cancelled = false

        queue.async { [weak self] in
            guard let self else { return }
            let roots = roots ?? SemanticIndex.roots
            var seen = 0, indexed = 0
            var freshStamps: [String: FileStamp] = [:]
            var kept: [Entry] = []
            var added: [Entry] = []

            self.lock.lock()
            let oldStamps = self.stamps
            let oldEntries = self.entries
            self.lock.unlock()

            // Old entries by path, built once. Filtering the whole array per
            // unchanged file made a no-op rebuild quadratic: 20,000 files
            // against 100,000 entries is two billion string comparisons, on
            // this queue, with `indexed` never moving so the progress callback
            // never fired either.
            var oldByPath: [String: [Entry]] = [:]
            for entry in oldEntries { oldByPath[entry.path, default: []].append(entry) }

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
                    let path = url.standardizedFileURL.path
                    // Roots can nest — ~/Documents and ~/Documents/Work — and
                    // a file under both is walked once per root. Processing it
                    // twice appended its passages twice on the first run, and
                    // then doubled what was kept on every run after that.
                    guard live.insert(path).inserted else { continue }
                    seen += 1

                    let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let stamp = FileStamp(
                        modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        size: Int64(values?.fileSize ?? 0)
                    )
                    freshStamps[path] = stamp

                    // Unchanged since last time: keep what was already computed.
                    if oldStamps[path] == stamp, let existing = oldByPath[path] {
                        kept.append(contentsOf: existing)
                        continue
                    }

                    guard let text = TextExtraction.text(of: url) else { continue }
                    let passages = TextExtraction.passages(text)
                    for (passage, vector) in zip(passages, Self.vectors(for: passages)) {
                        guard let vector else { continue }
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
                // A request that arrived mid-pass starts now, with the roots
                // it asked for. A request that named none passes nil through,
                // so the settings list is read afresh and a root added since
                // this pass began is walked.
                if let queued = self.queuedRebuild {
                    self.queuedRebuild = nil
                    self.rebuild(roots: queued.roots,
                                 progress: queued.progress, finished: queued.finished)
                }
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
