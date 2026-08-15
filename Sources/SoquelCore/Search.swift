import AppKit

/// Recursive search over the filesystem, streaming results as they are found so
/// a large tree stays usable while it is still being walked.
///
/// Deliberately not Spotlight: it searches what is actually on disk, including
/// folders Spotlight excludes, and it works on a volume that was never indexed.
///
/// The governing rule is that nothing is skipped silently. Every exclusion is a
/// setting the user can see and turn off, and whatever is skipped is counted and
/// reported.
final class FileSearch {
    enum Mode: String, CaseIterable {
        case name, contents, meaning

        var title: String {
            switch self {
            case .name: return "File name"
            case .contents: return "File contents"
            case .meaning: return "Meaning"
            }
        }
    }

    /// How the typed text is matched.
    enum Matching: String, CaseIterable {
        case contains, regex, glob

        var title: String {
            switch self {
            case .contains: return "Contains"
            case .regex: return "Regular expression"
            case .glob: return "Glob (*.txt)"
            }
        }
    }

    enum Scope: String, CaseIterable {
        case folder, home, everywhere

        var title: String {
            switch self {
            case .folder: return "This folder"
            case .home: return "Home"
            case .everywhere: return "Everywhere"
            }
        }
    }

    struct Query {
        var text: String
        var mode: Mode = .name
        var matching: Matching = .contains
        var scope: Scope = .folder
        /// Where `.folder` starts from.
        var root: URL
        var caseSensitive = false
        /// On by default. Hiding dotfiles from a search someone deliberately ran
        /// is the single most complained-about thing about Finder's search.
        var includeHidden = true
        /// App bundles are folders; their contents are searched unless this is off.
        var includePackages = true
        /// Directory levels below the root; nil means unlimited.
        var maximumDepth: Int?
        /// Stops the walk once this many hits are found, and says so.
        var resultLimit = 5000
        /// Skips whatever the repository's .gitignore files exclude. Off by
        /// default: a search that silently hides files is the complaint this
        /// whole engine exists to answer, so honouring ignore files is a choice
        /// the user makes and the summary reports.
        var respectGitignore = false
    }

    struct Hit {
        let url: URL
        let isDirectory: Bool
        /// The matching line, for a contents search.
        let excerpt: String?
        /// Lower sorts first. Name matches outrank content matches, and an exact
        /// name outranks a substring buried in the middle of one.
        let rank: Int
    }

    struct Summary {
        var examined = 0
        var found = 0
        /// Files skipped because they were too big to read for a contents search.
        var skippedTooLarge = 0
        /// Files that were not valid UTF-8, so could not be searched as text.
        var skippedUnreadable = 0
        /// Files that could not be opened at all, usually a permissions
        /// refusal. Kept apart from `skippedUnreadable`: a file the search was
        /// not allowed to read is a different fact from one that holds no text,
        /// and the summary used to fold the two together as "not text".
        var skippedDenied = 0
        /// Directories that could not be entered, usually a permissions refusal.
        var skippedUnreachable = 0
        /// Paths excluded by a .gitignore, when that option is on.
        var skippedIgnored = 0
        var hitLimit = false
        var cancelled = false
        /// Anything else worth saying, such as an index that is not built yet.
        var notes: [String] = []

        /// Plain-language account of anything that was not looked at, so a
        /// result of "nothing" can be told apart from "I did not look".
        var caveats: [String] {
            var notes: [String] = []
            if hitLimit { notes.append("stopped at \(found) results") }
            if skippedTooLarge > 0 { notes.append("\(skippedTooLarge) too large to read") }
            if skippedUnreadable > 0 { notes.append("\(skippedUnreadable) not text") }
            if skippedDenied > 0 { notes.append("\(skippedDenied) unreadable") }
            if skippedUnreachable > 0 { notes.append("\(skippedUnreachable) unreadable folders") }
            if skippedIgnored > 0 { notes.append("\(skippedIgnored) ignored by .gitignore") }
            notes.append(contentsOf: self.notes)
            return notes
        }
    }

    /// Searching the semantic index. Instant where the walk is not, because
    /// the reading happened when the folder was indexed.
    private func runSemantic(
        _ query: Query,
        batch: @escaping ([Hit]) -> Void,
        finished: @escaping (Summary) -> Void
    ) {
        var summary = Summary()
        guard SemanticIndex.isAvailable else {
            summary.notes.append("meaning search needs macOS's English sentence model, which is missing")
            finished(summary)
            return
        }

        let index = SemanticIndex.shared
        guard index.entryCount > 0 else {
            summary.notes.append("nothing is indexed yet — use “Index This Folder for Meaning” on a folder")
            finished(summary)
            return
        }

        // Scope narrows the same way it does for the walk: home is the home
        // folder, not everything indexed — a root outside home can be indexed,
        // and its passages do not belong in a home-scoped search.
        let folder: URL?
        switch query.scope {
        case .folder: folder = query.root
        case .home: folder = FileManager.default.homeDirectoryForCurrentUser
        case .everywhere: folder = nil
        }
        let found = index.search(query.text, within: folder, limit: query.resultLimit)

        var hits: [Hit] = []
        for (rank, hit) in found.enumerated() {
            let isDirectory = (try? hit.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            hits.append(Hit(url: hit.url, isDirectory: isDirectory,
                            excerpt: hit.passage, rank: rank))
        }
        summary.examined = index.entryCount
        summary.found = hits.count
        if hits.isEmpty {
            summary.notes.append("nothing close enough in \(index.fileCount) indexed file(s)")
        }
        batch(hits)
        finished(summary)
    }

    /// Compiled form of the query text, built once rather than per file.
    enum Matcher {
        case substring(String)
        case regex(NSRegularExpression)

        func matches(_ candidate: String) -> Bool {
            switch self {
            case .substring(let needle):
                return candidate.contains(needle)
            case .regex(let expression):
                let range = NSRange(candidate.startIndex..., in: candidate)
                return expression.firstMatch(in: candidate, options: [], range: range) != nil
            }
        }
    }

    /// Which run is the live one.
    ///
    /// `cancelled` was a plain Bool written from the main thread and read on
    /// the walk queue with nothing between them — a data race the optimiser is
    /// free to fold away. It was also reset at the top of `run`, so reusing one
    /// instance (cancel, then run again) cleared the flag before the walk in
    /// flight had observed it: the old filesystem-wide walk ran to completion
    /// and the new query queued up behind it. Starting and cancelling both move
    /// the generation on, so neither can undo the other.
    private let lock = NSLock()
    private var generation = 0
    /// The generation of the most recent `run`. `cancel` moves `generation` on
    /// without touching this, which is what separates "stop, and tell me you
    /// stopped" from "forget this, I have asked for something else".
    private var lastStarted = 0

    /// Whether this walk should still be walking.
    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    /// Whether this walk's results are still wanted. A cancelled run reports
    /// back — the caller asked it to stop and can see `cancelled` in the
    /// summary — but a run replaced by a newer one says nothing at all.
    private func shouldDeliver(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == lastStarted
    }

    private func beginRun() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        lastStarted = generation
        return generation
    }
    private let queue = DispatchQueue(label: "app.soquel.search", qos: .userInitiated)

    /// Files larger than this are not read for a contents search; they are
    /// almost never prose or source, and reading them would stall the walk.
    /// Anything skipped for this reason is counted and reported.
    static let maximumContentsBytes = 8 * 1024 * 1024

    func cancel() {
        lock.lock(); generation += 1; lock.unlock()
    }

    /// Checks the query text without building anything, so a caller can show
    /// the error before it starts a search.
    static func compile(_ query: Query) -> Result<Void, Error> {
        matcher(for: query).map { _ in () }
    }

    /// Builds the matcher, or the error the pattern failed with.
    ///
    /// This used to swallow the `NSRegularExpression` failure with `try?` and
    /// return nil, which left every caller with a bare "no matcher" and nothing
    /// to say about why. Carrying the error is what lets `run` report a pattern
    /// error rather than a search that found nothing.
    private static func matcher(for query: Query) -> Result<Matcher, Error> {
        let text = query.caseSensitive ? query.text : query.text.lowercased()
        switch query.matching {
        case .contains:
            return .success(.substring(text))
        case .regex:
            return regularExpression(pattern: query.text, caseSensitive: query.caseSensitive)
        case .glob:
            // A glob is a regex with two wildcards; translating keeps one engine.
            var pattern = "^"
            for character in query.text {
                switch character {
                case "*": pattern += ".*"
                case "?": pattern += "."
                default: pattern += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            pattern += "$"
            return regularExpression(pattern: pattern, caseSensitive: query.caseSensitive)
        }
    }

    private static func regularExpression(pattern: String, caseSensitive: Bool) -> Result<Matcher, Error> {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        do {
            return .success(.regex(try NSRegularExpression(pattern: pattern, options: options)))
        } catch {
            return .failure(error)
        }
    }

    /// Roots to walk for a scope. "Everywhere" means the whole filesystem,
    /// mounted volumes included, not just the home folder.
    static func roots(for query: Query) -> [URL] {
        switch query.scope {
        case .folder:
            return [query.root]
        case .home:
            return [FileManager.default.homeDirectoryForCurrentUser]
        case .everywhere:
            // Every volume is mounted at a path below "/" — an external drive at
            // "/Volumes/Foo" — and `FileManager.enumerator` crosses mount points,
            // so one walk of "/" already reaches all of them. Adding the entries
            // from `mountedVolumeURLs` as extra roots, as this used to, walked
            // each attached volume a second time: every hit on it appeared twice,
            // `examined` counted it twice, and the result limit was reached
            // halfway through the filesystem while reporting the cap as a total.
            return [URL(fileURLWithPath: "/")]
        }
    }

    /// How well a name matches, lower being better. Name hits always outrank
    /// content hits so a file called "invoice" is never buried under files that
    /// merely mention the word.
    static func rank(name: String, needle: String, isContentMatch: Bool) -> Int {
        if isContentMatch { return 400 }
        let lowered = name.lowercased()
        let target = needle.lowercased()
        if lowered == target { return 0 }
        if lowered.deletingPathExtensionComponent == target { return 10 }
        if lowered.hasPrefix(target) { return 100 }
        if lowered.contains(target) { return 200 }
        return 300
    }

    /// - Parameters:
    ///   - batch: called on the main thread with each group of hits.
    ///   - finished: called on the main thread once, with what was and was not looked at.
    func run(
        _ query: Query,
        batch: @escaping ([Hit]) -> Void,
        finished: @escaping (Summary) -> Void
    ) {
        let token = beginRun()
        guard !query.text.isEmpty else {
            finished(Summary())
            return
        }

        // Meaning does not walk anything: the passages were read and embedded
        // when the folder was indexed, so the answer is a comparison against
        // what is already in memory. It is still an embedding pass plus a
        // multiply over every stored vector — and the first touch loads the
        // model — which is too much for the main thread on a keystroke, so it
        // runs on the search queue and delivers on main like the walks do.
        if query.mode == .meaning {
            queue.async { [weak self] in
                guard let self else { return }
                self.runSemantic(query, batch: { hits in
                    DispatchQueue.main.async {
                        guard self.shouldDeliver(token) else { return }
                        batch(hits)
                    }
                }, finished: { summary in
                    DispatchQueue.main.async {
                        guard self.shouldDeliver(token) else { return }
                        finished(summary)
                    }
                })
            }
            return
        }

        let matcher: Matcher
        switch Self.matcher(for: query) {
        case .success(let built):
            matcher = built
        case .failure(let error):
            // A pattern that does not compile used to finish with a default
            // Summary — nothing found, nothing examined, nothing said — which
            // the panel prints as "No matches in 0 items", indistinguishable
            // from a search that ran and came back empty. `SearchWindowController`
            // escapes it only because it calls `compile` first; a saved search
            // restored from disk with a broken pattern does not.
            var summary = Summary()
            summary.notes.append("pattern error: \(error.localizedDescription)")
            finished(summary)
            return
        }
        let roots = Self.roots(for: query)

        queue.async { [weak self] in
            guard let self else { return }
            var pending: [Hit] = []
            var summary = Summary()

            outer: for root in roots {
                // Rules above the starting folder still apply, so the stack is
                // collected up to the repository root before the walk begins.
                let ignores = query.respectGitignore ? IgnoreStack.forTree(startingAt: root) : nil

                var options: FileManager.DirectoryEnumerationOptions = []
                if !query.includeHidden { options.insert(.skipsHiddenFiles) }
                if !query.includePackages { options.insert(.skipsPackageDescendants) }

                let rootDepth = root.standardizedFileURL.pathComponents.count
                // On APFS the data volume is mounted twice: firmlinks graft
                // it into "/", and the same files appear again under
                // /System/Volumes/Data. A walk that starts at "/" reaches
                // every one of those files through its firmlinked path, so
                // the second mount is pruned there and nothing is skipped.
                // The test is the root, not the scope: a folder search of
                // the disk root is the identical walk and duplicated every
                // hit when only the everywhere scope was pruned. A walk
                // rooted anywhere else that still meets the mount, such as
                // /System, has no other way to those files, so it descends.
                let prunesDataVolume = root.standardizedFileURL.path == "/"
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: options,
                    errorHandler: { _, _ in
                        summary.skippedUnreachable += 1
                        return true   // keep going; a refused folder is not the end
                    }
                )

                while let candidate = enumerator?.nextObject() as? URL {
                    if !self.isCurrent(token) { summary.cancelled = true; break outer }

                    if prunesDataVolume, candidate.path == "/System/Volumes/Data" {
                        enumerator?.skipDescendants()
                        continue
                    }

                    let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDirectory = values?.isDirectory ?? false
                    let name = candidate.lastPathComponent

                    if let limit = query.maximumDepth {
                        // Counted from this root, so a direct child sits at 1.
                        let depth = candidate.standardizedFileURL.pathComponents.count - rootDepth
                        // Pruning belongs at the parent, on the directory that
                        // sits at the limit. This used to wait for the
                        // enumerator to hand over an entry that was already
                        // past the limit and skip descendants only then, so a
                        // whole level below the limit was enumerated, stat'd
                        // and — because `examined` was incremented before the
                        // check — counted as searched. The depth test remains
                        // the rule; `skipDescendants` is what keeps the
                        // enumerator from producing those entries at all.
                        if isDirectory, depth >= limit { enumerator?.skipDescendants() }
                        if depth > limit { continue }
                    }

                    if let ignores {
                        // A nested .gitignore only applies below itself, so it
                        // is read as the walk reaches its directory.
                        if isDirectory { ignores.pushIgnoreFile(in: candidate) }
                        if ignores.ignores(candidate, isDirectory: isDirectory) {
                            summary.skippedIgnored += 1
                            // Not descending into an ignored folder is the whole
                            // point: node_modules is why people ask for this.
                            if isDirectory { enumerator?.skipDescendants() }
                            continue
                        }
                    }

                    // Counted after the filters rather than at the top of the
                    // loop: an entry past the depth limit is outside what was
                    // asked for, and an ignored one is already reported on its
                    // own line, so counting either here would put paths nobody
                    // searched into the total the panel prints.
                    summary.examined += 1

                    switch query.mode {
                    case .meaning:
                        continue   // handled before the walk; never reached
                    case .name:
                        let subject = query.caseSensitive ? name : name.lowercased()
                        if matcher.matches(subject) {
                            pending.append(Hit(
                                url: candidate, isDirectory: isDirectory, excerpt: nil,
                                rank: Self.rank(name: name, needle: query.text, isContentMatch: false)
                            ))
                            summary.found += 1
                        }
                    case .contents:
                        guard !isDirectory else { continue }
                        guard (values?.fileSize ?? 0) <= Self.maximumContentsBytes else {
                            summary.skippedTooLarge += 1
                            continue
                        }
                        switch Self.firstMatchingLine(in: candidate, matcher: matcher, caseSensitive: query.caseSensitive) {
                        case .match(let excerpt):
                            pending.append(Hit(
                                url: candidate, isDirectory: false, excerpt: excerpt,
                                rank: Self.rank(name: name, needle: query.text, isContentMatch: true)
                            ))
                            summary.found += 1
                        case .notText:
                            summary.skippedUnreadable += 1
                        case .unreadable:
                            summary.skippedDenied += 1
                        case .noMatch:
                            break
                        }
                    }

                    if summary.found >= query.resultLimit {
                        summary.hitLimit = true
                        break outer
                    }

                    if pending.count >= 40 {
                        let flush = pending.sorted { $0.rank < $1.rank }
                        pending = []
                        DispatchQueue.main.async {
                            guard self.shouldDeliver(token) else { return }
                            batch(flush)
                        }
                    }
                }
            }

            let remainder = pending.sorted { $0.rank < $1.rank }
            let outcome = summary
            DispatchQueue.main.async {
                // A superseded run says nothing. Its hits belong to a query the
                // user has moved on from, and its summary would stop the
                // spinner for the search that replaced it. A cancelled run
                // still reports, with `cancelled` set.
                guard self.shouldDeliver(token) else { return }
                if !remainder.isEmpty { batch(remainder) }
                finished(outcome)
            }
        }
    }

    enum ContentResult {
        case match(String)
        case noMatch
        /// Not valid UTF-8, so it cannot be searched as text. Counted, not hidden.
        case notText
        /// Could not be opened at all, usually because the search has no
        /// permission to read it. A read refusal used to come back as
        /// `notText`, so a chmod 000 file was reported as binary when the
        /// truth is that nobody looked inside it.
        case unreadable
    }

    /// Reads a file as UTF-8 and returns the first line that matches.
    static func firstMatchingLine(in url: URL, matcher: Matcher, caseSensitive: Bool) -> ContentResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unreadable }
        guard let text = String(data: data, encoding: .utf8) else { return .notText }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let haystack = caseSensitive ? String(line) : line.lowercased()
            if matcher.matches(haystack) {
                return .match(String(line.prefix(200)).trimmingCharacters(in: .whitespaces))
            }
        }
        return .noMatch
    }

    /// Exposed for tests: matches a single name against a query. A pattern that
    /// does not compile matches nothing here; callers that need to tell that
    /// apart from a genuine miss go through `compile` or `run`.
    static func matches(name: String, query: Query) -> Bool {
        guard case .success(let matcher) = matcher(for: query) else { return false }
        return matcher.matches(query.caseSensitive ? name : name.lowercased())
    }
}

private extension String {
    /// "report.txt" → "report", for ranking a name that matches but for its
    /// extension.
    var deletingPathExtensionComponent: String {
        (self as NSString).deletingPathExtension
    }
}
