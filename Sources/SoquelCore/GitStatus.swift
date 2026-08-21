import Foundation

/// What Git thinks of a file. Deliberately display-only: Soquel shows status
/// and repository-relative paths, and does not try to be a Git client.
enum GitState: String {
    case modified, added, deleted, renamed, untracked, ignored, conflicted, clean

    /// A letter as well as a colour, so status is legible without colour vision.
    var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .ignored: return "·"
        case .conflicted: return "!"
        case .clean: return ""
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .conflicted: return "Conflict"
        case .clean: return "Unchanged"
        }
    }

    /// What the letter means, in a sentence, for the tooltip.
    ///
    /// The one-word label was what the tooltip used to say, and "Untracked"
    /// on its own does not tell somebody who does not already know what "?"
    /// means. Each of these says what Git thinks and what would change it.
    var explanation: String {
        switch self {
        case .modified:
            return "Modified — changed since the last commit, and not staged yet."
        case .added:
            return "Added — staged, and will go into the next commit."
        case .deleted:
            return "Deleted — gone from the working tree, still in the last commit."
        case .renamed:
            return "Renamed — Git matched it to a file that used to have another name."
        case .untracked:
            return "Untracked — Git is not following this file. "
                + "“git add” starts tracking it; .gitignore hides it."
        case .ignored:
            return "Ignored — a rule in .gitignore tells Git to leave it alone."
        case .conflicted:
            return "Conflict — a merge or rebase left both sides in the file. "
                + "It has to be resolved by hand."
        case .clean:
            return "Unchanged since the last commit."
        }
    }

    /// The whole column explained at once, for the header.
    static var legend: String {
        let states: [GitState] = [.modified, .added, .deleted, .renamed,
                                  .untracked, .ignored, .conflicted]
        let rows = states.map { "\($0.badge)  \($0.label)" }.joined(separator: "\n")
        return "Git status\n\n" + rows
            + "\n\nA folder is marked when anything inside it is."
    }

    /// Porcelain v1 uses two columns: index state, then working-tree state.
    /// The working tree wins for display because it is what the user just did.
    static func from(porcelainCode code: String) -> GitState? {
        guard code.count >= 2 else { return nil }
        let characters = Array(code)
        let index = characters[0]
        let worktree = characters[1]

        if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") {
            return .conflicted
        }
        if index == "?" && worktree == "?" { return .untracked }
        if index == "!" && worktree == "!" { return .ignored }

        for character in [worktree, index] {
            switch character {
            case "M": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .added
            case "T": return .modified
            default: continue
            }
        }
        return nil
    }
}

/// Reads `git status` for a directory, off the main thread, and caches the
/// result per repository until something changes.
final class GitStatusReader {
    static let shared = GitStatusReader()

    private let queue = DispatchQueue(label: "app.soquel.git", qos: .utility)
    private var cache: [URL: [String: GitState]] = [:]
    /// Completions waiting on a run already under way, per repository. One
    /// global generation counter used to stand here, and it dropped the
    /// answer for every pane except the last one to ask.
    private var pending: [URL: [([String: GitState], URL?) -> Void]] = [:]
    /// Roots where a request arrived while a run was already reading. Such a
    /// request can be the echo of a change made after that run started, so
    /// the run's snapshot may not include it; one fresh run follows.
    private var dirtyRoots: Set<URL> = []

    /// Statuses keyed by absolute path, for every changed file in the
    /// repository containing `directory`. Returns immediately with a cached
    /// answer when one exists, then calls back with fresh data. The
    /// completion can run more than once: a request that joins a read
    /// already under way gets that read's snapshot first and the follow-up
    /// run's answer after it.
    func status(
        for directory: URL,
        cached: (([String: GitState]) -> Void)? = nil,
        completion: @escaping ([String: GitState], URL?) -> Void
    ) {
        guard let root = gitRoot(for: directory) else {
            completion([:], nil)
            return
        }
        if let hit = cache[root] { cached?(hit) }

        // A run for this repository is already reading; every asker gets its
        // result rather than starting another `git status` on the same tree.
        if pending[root] != nil {
            pending[root]?.append(completion)
            // This request may be the result of a change the running read
            // started before, so its snapshot cannot be trusted to include
            // it. Remember to read again once the run finishes, or stale
            // statuses would stick until an unrelated filesystem event.
            dirtyRoots.insert(root)
            return
        }
        pending[root] = [completion]
        startRun(root: root)
    }

    /// One `git status` run for one repository. When a request joined while
    /// the run was reading, the run delivers its snapshot — the newest answer
    /// that exists — and immediately reads again, keeping the same waiters
    /// registered so they also hear the corrected answer.
    private func startRun(root: URL) {
        queue.async { [weak self] in
            let statuses = Self.read(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[root] = statuses
                if self.dirtyRoots.remove(root) != nil {
                    for callback in self.pending[root] ?? [] { callback(statuses, root) }
                    self.startRun(root: root)
                } else {
                    let waiting = self.pending.removeValue(forKey: root) ?? []
                    for callback in waiting { callback(statuses, root) }
                }
            }
        }
    }

    func invalidate() {
        cache.removeAll()
    }

    /// Runs `git status --porcelain`. Any failure — no git binary, not a
    /// repository, a permissions problem — yields no statuses rather than a
    /// guess.
    static func read(root: URL) -> [String: GitState] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "status", "--porcelain", "-z", "--no-renames"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [:] }

        return parse(porcelainZ: text, root: root)
    }

    /// `-z` output is NUL-separated with no quoting, so filenames containing
    /// spaces, quotes, or newlines parse correctly.
    static func parse(porcelainZ text: String, root: URL) -> [String: GitState] {
        var result: [String: GitState] = [:]
        for entry in text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            guard let state = GitState.from(porcelainCode: code) else { continue }
            let absolute = root.appendingPathComponent(path).standardizedFileURL.path

            // A change anywhere inside a folder marks the folder itself, so a
            // collapsed directory still shows that something under it changed.
            result[absolute] = state
            var parent = URL(fileURLWithPath: absolute).deletingLastPathComponent()
            while parent.path.count > root.path.count {
                if result[parent.path] == nil { result[parent.path] = .modified }
                parent = parent.deletingLastPathComponent()
            }
        }
        return result
    }
}
