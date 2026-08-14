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

    /// Statuses keyed by absolute path, for every changed file in the
    /// repository containing `directory`. Returns immediately with a cached
    /// answer when one exists, then calls back with fresh data.
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
            return
        }
        pending[root] = [completion]
        queue.async { [weak self] in
            let statuses = Self.read(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[root] = statuses
                let waiting = self.pending.removeValue(forKey: root) ?? []
                for callback in waiting { callback(statuses, root) }
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
