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
            summary.notes.append("nothing is indexed yet — add a folder in Settings → Search")
            finished(summary)
            return
        }

        // Scope narrows the same way it does for the walk.
        let folder: URL? = query.scope == .folder ? query.root : nil
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

    private var cancelled = false
    private let queue = DispatchQueue(label: "app.soquel.search", qos: .userInitiated)

    /// Files larger than this are not read for a contents search; they are
    /// almost never prose or source, and reading them would stall the walk.
    /// Anything skipped for this reason is counted and reported.
    static let maximumContentsBytes = 8 * 1024 * 1024

    func cancel() { cancelled = true }

    /// Builds the matcher, or returns nil when a regular expression does not
    /// compile — the caller shows the error rather than searching for nothing.
    static func compile(_ query: Query) -> Result<Void, Error> {
        guard query.matching == .regex else { return .success(()) }
        do {
            _ = try NSRegularExpression(pattern: query.text, options: query.caseSensitive ? [] : [.caseInsensitive])
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func matcher(for query: Query) -> Matcher? {
        let text = query.caseSensitive ? query.text : query.text.lowercased()
        switch query.matching {
        case .contains:
            return .substring(text)
        case .regex:
            let options: NSRegularExpression.Options = query.caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: query.text, options: options) else { return nil }
            return .regex(expression)
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
            let options: NSRegularExpression.Options = query.caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return .regex(expression)
        }
    }

    /// Roots to walk for a scope. "Everywhere" means the whole filesystem plus
    /// mounted volumes, not just the home folder.
    static func roots(for query: Query) -> [URL] {
        switch query.scope {
        case .folder:
            return [query.root]
        case .home:
            return [FileManager.default.homeDirectoryForCurrentUser]
        case .everywhere:
            var roots = [URL(fileURLWithPath: "/")]
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
            ) ?? []
            // "/" already covers the boot volume; other mounts are separate trees.
            roots.append(contentsOf: volumes.filter { $0.path != "/" })
            return roots
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
        cancelled = false
        guard !query.text.isEmpty else {
            finished(Summary())
            return
        }

        // Meaning does not walk anything: the passages were read and embedded
        // when the folder was indexed, so the answer is a comparison against
        // what is already in memory.
        if query.mode == .meaning {
            runSemantic(query, batch: batch, finished: finished)
            return
        }

        guard let matcher = Self.matcher(for: query) else {
            finished(Summary())
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
                    if self.cancelled { summary.cancelled = true; break outer }
                    summary.examined += 1

                    if let limit = query.maximumDepth,
                       candidate.standardizedFileURL.pathComponents.count - rootDepth > limit {
                        enumerator?.skipDescendants()
                        continue
                    }

                    let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDirectory = values?.isDirectory ?? false
                    let name = candidate.lastPathComponent

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
                        DispatchQueue.main.async { batch(flush) }
                    }
                }
            }

            let remainder = pending.sorted { $0.rank < $1.rank }
            let outcome = summary
            DispatchQueue.main.async {
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
    }

    /// Reads a file as UTF-8 and returns the first line that matches.
    static func firstMatchingLine(in url: URL, matcher: Matcher, caseSensitive: Bool) -> ContentResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .notText }
        guard let text = String(data: data, encoding: .utf8) else { return .notText }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let haystack = caseSensitive ? String(line) : line.lowercased()
            if matcher.matches(haystack) {
                return .match(String(line.prefix(200)).trimmingCharacters(in: .whitespaces))
            }
        }
        return .noMatch
    }

    /// Exposed for tests: matches a single name against a query.
    static func matches(name: String, query: Query) -> Bool {
        guard let matcher = matcher(for: query) else { return false }
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
