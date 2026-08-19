import Foundation

/// Reading and, when the user has asked for it, changing a git repository.
///
/// Soquel was display-only by design. Branch work breaks that on purpose and
/// behind a switch: everything here that writes is refused outright unless
/// `Prefs.gitActions` is on, and even then it refuses rather than tidies. A
/// file manager that stashes your work to make a checkout succeed is a file
/// manager that loses work, and there is no undo for that.
enum GitRepo {
    struct Branch: Equatable {
        let name: String
        let isCurrent: Bool
        /// Commits this branch is ahead of and behind its upstream. Nil when
        /// it has no upstream to compare against.
        let ahead: Int?
        let behind: Int?
    }

    enum Failure: LocalizedError {
        case notARepository
        case disabled
        case dirtyTree([String])
        /// A ref whose name git would read as an option rather than a ref.
        case unusableRef(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: return "This folder is not in a git repository"
            case .disabled: return "Git actions are off. Settings › General turns them on."
            case .dirtyTree(let files):
                let names = files.prefix(3).joined(separator: ", ")
                let more = files.count > 3 ? " and \(files.count - 3) more" : ""
                return "There are uncommitted changes in \(names)\(more). "
                    + "Commit or stash them first — Soquel will not do it for you."
            case .unusableRef(let name):
                return "“\(name)” cannot be used as a branch name here: a name "
                    + "beginning with a dash is read by git as an option, not a branch."
            case .git(let message):
                return message.isEmpty ? "git refused" : message
            }
        }
    }

    /// Whether a name can be handed to git as a ref.
    ///
    /// git itself refuses to *create* a branch whose name starts with a dash,
    /// but `update-ref` will, and a repository can arrive from anywhere. Such
    /// a name reaching an argument list is read as an option, not a ref, and
    /// git has options that write files — `--output=<file>` truncates whatever
    /// it names. Every ref is checked here as well as separated by `--` below,
    /// because either alone is one mistake away from the same hole.
    static func isSafeRef(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
    }

    /// Runs git and hands back what it printed. Never on the main thread.
    private static func run(_ arguments: [String], in root: URL) -> (status: Int32, out: String, error: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "-C", root.path] + arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            return (127, "", error.localizedDescription)
        }
        // Both pipes are drained before waiting: a command with more output
        // than the buffer holds would otherwise block for ever.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    // MARK: - Reading

    /// Every local branch, current one first.
    static func branches(in root: URL, completion: @escaping (Result<[Branch], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // %(HEAD) marks the checked-out branch, and the track field gives
            // "ahead 2, behind 1" without a second call per branch.
            let result = run(["for-each-ref", "--format=%(HEAD)\u{1}%(refname:short)\u{1}%(upstream:track)",
                              "refs/heads"], in: root)
            guard result.status == 0 else {
                let error = Failure.git(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            var branches: [Branch] = []
            for line in result.out.components(separatedBy: "\n") where !line.isEmpty {
                let fields = line.components(separatedBy: "\u{1}")
                guard fields.count >= 2 else { continue }
                let track = fields.count > 2 ? fields[2] : ""
                branches.append(Branch(
                    name: fields[1],
                    isCurrent: fields[0] == "*",
                    ahead: count(in: track, after: "ahead "),
                    behind: count(in: track, after: "behind ")
                ))
            }
            branches.sort { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }
            DispatchQueue.main.async { completion(.success(branches)) }
        }
    }

    /// Pulls "2" out of "[ahead 2, behind 1]".
    static func count(in track: String, after marker: String) -> Int? {
        guard let range = track.range(of: marker) else { return nil }
        let digits = track[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Files that differ between two refs, as a unified diff.
    static func diff(_ from: String, _ to: String, in root: URL,
                     completion: @escaping (Result<String, Error>) -> Void) {
        guard isSafeRef(from), isSafeRef(to) else {
            completion(.failure(Failure.unusableRef([from, to].first { !isSafeRef($0) } ?? "")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(["diff", "--no-color", from, to, "--"], in: root)
            DispatchQueue.main.async {
                guard result.status == 0 else {
                    completion(.failure(Failure.git(result.error.trimmingCharacters(in: .whitespacesAndNewlines))))
                    return
                }
                completion(.success(result.out))
            }
        }
    }

    /// What a single file looks like against HEAD — the diff for the file the
    /// list already badges as modified.
    static func diff(file url: URL, in root: URL,
                     completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(["diff", "--no-color", "--", url.path], in: root)
            DispatchQueue.main.async {
                guard result.status == 0 else {
                    completion(.failure(Failure.git(result.error.trimmingCharacters(in: .whitespacesAndNewlines))))
                    return
                }
                completion(.success(result.out))
            }
        }
    }

    /// Paths with uncommitted changes. Empty means the tree is clean.
    static func dirtyPaths(in root: URL) -> [String] {
        let result = run(["status", "--porcelain", "-z", "--no-renames"], in: root)
        guard result.status == 0 else { return [] }
        return result.out
            .split(separator: "\0", omittingEmptySubsequences: true)
            .compactMap { entry in
                entry.count > 3 ? String(entry.dropFirst(3)) : nil
            }
    }

    // MARK: - Writing

    /// Whether the branch-changing half of this is available.
    static var actionsEnabled: Bool { Prefs.gitActions }

    /// Switches branch, and refuses rather than improvises.
    ///
    /// A dirty tree stops it: git would either refuse itself or carry the
    /// changes across, and neither is something to do to somebody's work
    /// without asking. Nothing here stashes, forces, or resets.
    static func checkout(_ branch: String, in root: URL,
                         completion: @escaping (Result<String, Error>) -> Void) {
        guard actionsEnabled else {
            completion(.failure(Failure.disabled))
            return
        }
        guard isSafeRef(branch) else {
            completion(.failure(Failure.unusableRef(branch)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let dirty = dirtyPaths(in: root)
            guard dirty.isEmpty else {
                DispatchQueue.main.async { completion(.failure(Failure.dirtyTree(dirty))) }
                return
            }
            let result = run(["checkout", branch, "--"], in: root)
            let message = (result.error + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.info(.app, "git checkout \(branch) in \(root.path) → \(result.status): \(message)")
            DispatchQueue.main.async {
                if result.status == 0 {
                    completion(.success("Switched to \(branch)"))
                } else {
                    completion(.failure(Failure.git(message)))
                }
            }
        }
    }
}
