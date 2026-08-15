import AppKit

/// Result of a completed operation, used for reporting and undo.
struct OperationResult {
    var succeeded: [URL] = []
    var failures: [(url: URL, error: Error)] = []
    /// Populated for trash so the items can be put back.
    var trashedPairs: [(original: URL, inTrash: URL)] = []
    /// Destination URLs actually created by a copy/move, for undo.
    var createdDestinations: [URL] = []
    /// What was written and where, one pair per placed item, for verification.
    /// Kept explicitly because `succeeded` and `createdDestinations` do not
    /// stay parallel: a merge appends one source but one destination per child
    /// placed, so pairing them by index checks the wrong files.
    var verifyPairs: [(source: URL, destination: URL)] = []
    /// Destinations that overwrote an existing item. Undoing these would delete
    /// the incoming file without bringing the replaced one back, so they are
    /// excluded from undo entries.
    var replacedDestinations: [URL] = []
    /// Folders that were merged into. Undo cannot separate what was already
    /// there from what arrived, so a merge is not offered as undoable.
    var mergedDestinations: [URL] = []
    /// Set when verified copy is on and the operation was a copy.
    var manifest: VerifiedCopy.Manifest?
}

enum ConflictChoice {
    /// Only offered when both sides are folders. Walks into them and resolves
    /// each child, instead of replacing the whole destination tree.
    case merge
    case replace, skip, keepBoth, cancel
}

/// What the user chose, and whether it stands for the rest of the operation.
struct ConflictResolution {
    var choice: ConflictChoice
    /// Reuse this answer for every later conflict without asking again.
    var applyToAll: Bool = false
    /// Leave a file alone when it looks the same on both sides.
    var skipIdentical: Bool = false
}

/// True when two files are the same size and carry the same modification date.
/// Used only to skip work the user asked to skip — never to decide a deletion.
func looksIdentical(_ a: URL, _ b: URL) -> Bool {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
    guard let left = try? a.resourceValues(forKeys: keys),
          let right = try? b.resourceValues(forKeys: keys),
          left.isDirectory == false, right.isDirectory == false,
          let leftSize = left.fileSize, let rightSize = right.fileSize,
          let leftDate = left.contentModificationDate, let rightDate = right.contentModificationDate
    else { return false }
    return leftSize == rightSize && abs(leftDate.timeIntervalSince(rightDate)) < 1
}

/// Executes file operations off the main thread and reports progress back on it.
/// Every operation reports per-file failures rather than aborting silently.
final class OperationEngine {
    static let shared = OperationEngine()

    private let queue = DispatchQueue(label: "app.soquel.fileops", qos: .userInitiated)
    private(set) var activeCount = 0

    /// Every window observes progress. A single closure meant opening a second
    /// window silently stole the first window's progress reporting.
    private var observers: [UUID: (Int, String?) -> Void] = [:]

    func addActivityObserver(_ observer: @escaping (Int, String?) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeActivityObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notify(_ label: String?) {
        for observer in observers.values { observer(activeCount, label) }
    }

    private func begin(_ label: String) {
        activeCount += 1
        notify(label)
    }

    private func end() {
        activeCount -= 1
        notify(nil)
    }

    // MARK: - Copy / Move

    /// - Parameter resolveConflict: called on the main thread for each existing
    ///   destination. Returning `.cancel` stops the whole operation.
    func transfer(
        _ sources: [URL],
        to directory: URL,
        move: Bool,
        resolveConflict: @escaping (URL, URL) -> ConflictResolution,
        completion: @escaping (OperationResult) -> Void
    ) {
        guard !sources.isEmpty else { return }
        begin(move ? "Moving \(sources.count) item(s)" : "Copying \(sources.count) item(s)")

        // Every transfer is a queued job, so it can be watched, paused and
        // cancelled rather than being a bar with no handles on it.
        let job = TransferJob(sources: sources, destination: directory, isMove: move, now: Date())
        TransferQueue.shared.add(job)

        DispatchQueue.global(qos: .utility).async {
            let measured = TransferQueue.measure(sources)
            DispatchQueue.main.async {
                job.markStarted(totalBytes: measured.bytes, totalFiles: measured.files, now: Date())
                TransferQueue.shared.notify()
            }
        }

        queue.async {
            let fm = FileManager()
            var result = OperationResult()
            // Set once the user ticks "Apply to all", so later conflicts in the
            // same operation are not re-asked.
            var standing: ConflictResolution?

            for source in sources {
                // Pausing holds the worker here; cancelling abandons the rest.
                while DispatchQueue.main.sync(execute: { job.state }) == .paused {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if DispatchQueue.main.sync(execute: { job.state }) == .cancelled { break }

                var destination = directory.appendingPathComponent(source.lastPathComponent)

                // Landing an item on its own path is a no-op for a move and
                // nothing at all for a copy — never a conflict to resolve, and
                // never a "Replace" that would delete the only copy.
                if samePath(source, destination) { continue }

                // Copying a folder into its own subtree would recurse forever.
                if isDescendant(destination, of: source) {
                    result.failures.append((source, SoquelError.destinationInsideSource(source.lastPathComponent)))
                    continue
                }

                var replacing = false
                if fm.fileExists(atPath: destination.path) {
                    let resolution = standing ?? DispatchQueue.main.sync { resolveConflict(source, destination) }
                    if resolution.applyToAll { standing = resolution }

                    // The checkbox state rides along on whichever button was
                    // pressed, Cancel included. Cancel means stop; an
                    // identical pair must not turn it into a skip that lets
                    // the rest of the operation carry on.
                    if resolution.choice != .cancel, resolution.skipIdentical,
                       looksIdentical(source, destination) { continue }

                    switch resolution.choice {
                    case .cancel:
                        DispatchQueue.main.async {
                            job.cancel()
                            TransferQueue.shared.notify()
                            self.end()
                            completion(result)
                        }
                        return
                    case .skip:
                        continue
                    case .keepBoth:
                        destination = Self.uniqueURL(for: destination, fileManager: fm)
                    case .replace:
                        replacing = true
                    case .merge:
                        // Merge is offered only when both sides are folders,
                        // but a standing "apply to all" answer taken at a
                        // folder conflict can land on a later file conflict.
                        // merge() must not run there — it would fail on a file
                        // and the pair would still be recorded as succeeded
                        // and merged. Dropping the source instead would end
                        // the job as Done while the destination silently
                        // keeps its stale file. So the source is copied
                        // beside the existing item under a unique name: the
                        // transfer delivers every file it promised, nothing
                        // is replaced, and the ordinary copy path below
                        // records and verifies the placement.
                        var sourceIsFolder: ObjCBool = false
                        var destinationIsFolder: ObjCBool = false
                        _ = fm.fileExists(atPath: source.path, isDirectory: &sourceIsFolder)
                        _ = fm.fileExists(atPath: destination.path, isDirectory: &destinationIsFolder)
                        guard sourceIsFolder.boolValue, destinationIsFolder.boolValue else {
                            destination = Self.uniqueURL(for: destination, fileManager: fm)
                            break
                        }

                        // Walk both trees and resolve child by child, instead of
                        // deleting the destination folder and everything under it.
                        let placedFrom = result.createdDestinations.count
                        let cancelled = self.merge(
                            source: source, into: destination, move: move, fileManager: fm,
                            standing: &standing, resolveConflict: resolveConflict, result: &result
                        )
                        // merge() places children one by one and never touches
                        // the job, so the advance the plain-copy path performs
                        // never runs for a merged source. Credit the job with
                        // what the merge actually created — cancelled or not,
                        // those bytes moved.
                        let placed = TransferQueue.measure(Array(result.createdDestinations[placedFrom...]))
                        let mergedName = source.lastPathComponent
                        DispatchQueue.main.async {
                            job.advance(bytes: placed.bytes, files: placed.files, file: mergedName, now: Date())
                            TransferQueue.shared.notify()
                        }
                        if cancelled {
                            DispatchQueue.main.async {
                                job.cancel()
                                TransferQueue.shared.notify()
                                self.end()
                                completion(result)
                            }
                            return
                        }
                        result.succeeded.append(source)
                        result.mergedDestinations.append(destination)
                        continue
                    }
                }

                do {
                    if replacing {
                        // Write beside the existing item first, then swap. A
                        // failure leaves the original file untouched instead of
                        // destroying it along with the incoming one.
                        let staged = Self.uniqueURL(
                            for: directory.appendingPathComponent(".soquel-incoming-" + source.lastPathComponent),
                            fileManager: fm
                        )
                        do {
                            if move {
                                try fm.moveItem(at: source, to: staged)
                            } else {
                                try fm.copyItem(at: source, to: staged)
                            }
                        } catch {
                            try? fm.removeItem(at: staged)
                            throw error
                        }
                        do {
                            try Self.swapIntoPlace(staged: staged, destination: destination, fileManager: fm)
                        } catch {
                            // Put a moved source back where it came from.
                            if move { try? fm.moveItem(at: staged, to: source) }
                            else { try? fm.removeItem(at: staged) }
                            throw error
                        }
                    } else if move {
                        try fm.moveItem(at: source, to: destination)
                    } else {
                        try fm.copyItem(at: source, to: destination)
                    }
                    result.succeeded.append(source)
                    result.createdDestinations.append(destination)
                    result.verifyPairs.append((source, destination))
                    if replacing { result.replacedDestinations.append(destination) }

                    // Measured at the destination so the job's progress is in
                    // the same units as its totals: a placed folder is many
                    // files, not one.
                    let moved = TransferQueue.measure([destination])
                    let name = source.lastPathComponent
                    DispatchQueue.main.async {
                        job.advance(bytes: moved.bytes, files: moved.files, file: name, now: Date())
                        TransferQueue.shared.notify()
                    }
                } catch {
                    result.failures.append((source, error))
                    let name = source.lastPathComponent
                    let message = error.localizedDescription
                    // Weigh the failure in files too. A source that cannot be
                    // measured still counts as one: one item did fail,
                    // whatever it held.
                    let failedFiles = max(1, TransferQueue.measure([source]).files)
                    DispatchQueue.main.async {
                        job.recordFailure(source, message, files: failedFiles)
                        job.advance(bytes: 0, file: name, now: Date())
                        TransferQueue.shared.notify()
                    }
                }
            }

            // A move leaves nothing at the source to compare against, so only
            // copies are verified.
            if VerifiedCopy.isEnabled, !move, !result.verifyPairs.isEmpty {
                let verified = VerifiedCopy.verify(pairs: result.verifyPairs)
                result.manifest = verified
                DispatchQueue.main.async {
                    job.recordVerification(verified)
                    TransferQueue.shared.notify()
                }
            }

            DispatchQueue.main.async {
                job.finish()
                TransferQueue.shared.notify()
                self.end()
                completion(result)
            }
        }
    }

    /// Merges `source` into the existing folder `destination`, child by child.
    ///
    /// This is what Finder does not do: its Replace on a folder unlinks the
    /// whole destination tree first, so anything in it that was not in the
    /// incoming folder is gone, with no Trash copy and nothing to undo.
    ///
    /// - Returns: true when the user cancelled the whole operation.
    private func merge(
        source: URL,
        into destination: URL,
        move: Bool,
        fileManager fm: FileManager,
        standing: inout ConflictResolution?,
        resolveConflict: @escaping (URL, URL) -> ConflictResolution,
        result: inout OperationResult
    ) -> Bool {
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            result.failures.append((source, error))
            return false
        }

        for child in children {
            var target = destination.appendingPathComponent(child.lastPathComponent)

            let childIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let targetExists = fm.fileExists(atPath: target.path)
            var targetIsDirectory: ObjCBool = false
            if targetExists { _ = fm.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) }

            // Nothing in the way: just place it.
            guard targetExists else {
                do {
                    if move { try fm.moveItem(at: child, to: target) }
                    else { try fm.copyItem(at: child, to: target) }
                    result.createdDestinations.append(target)
                    result.verifyPairs.append((child, target))
                } catch {
                    result.failures.append((child, error))
                }
                continue
            }

            // Two folders with the same name merge again, all the way down.
            if childIsDirectory && targetIsDirectory.boolValue {
                if merge(source: child, into: target, move: move, fileManager: fm,
                         standing: &standing, resolveConflict: resolveConflict, result: &result) {
                    return true
                }
                continue
            }

            let resolution = standing ?? DispatchQueue.main.sync { resolveConflict(child, target) }
            if resolution.applyToAll { standing = resolution }
            // As in transfer(): a Cancel that happens to land on an identical
            // pair is still a cancel, not a skip.
            if resolution.choice != .cancel, resolution.skipIdentical,
               looksIdentical(child, target) { continue }

            switch resolution.choice {
            case .cancel:
                return true
            case .skip:
                continue
            case .merge, .keepBoth:
                // Merge is only meaningful for two folders. A standing Merge
                // answer landing on a file conflict copies the file beside the
                // existing one, as the top level does: skipping it silently
                // would end the job as Done while the destination keeps its
                // stale file, and nothing anywhere would say so.
                target = Self.uniqueURL(for: target, fileManager: fm)
                do {
                    if move { try fm.moveItem(at: child, to: target) }
                    else { try fm.copyItem(at: child, to: target) }
                    result.createdDestinations.append(target)
                    result.verifyPairs.append((child, target))
                } catch {
                    result.failures.append((child, error))
                }
            case .replace:
                do {
                    try self.replaceItem(at: target, with: child, move: move, fileManager: fm)
                    result.createdDestinations.append(target)
                    result.replacedDestinations.append(target)
                    result.verifyPairs.append((child, target))
                } catch {
                    result.failures.append((child, error))
                }
            }
        }

        // A move leaves the source folder behind once its contents have gone.
        // Only remove it when it is genuinely empty — never recursively.
        if move, let remaining = try? fm.contentsOfDirectory(atPath: source.path), remaining.isEmpty {
            try? fm.removeItem(at: source)
        }
        return false
    }

    /// Puts a staged item at `destination`, keeping whatever is already there
    /// until the swap has actually happened.
    ///
    /// Removing the destination first opens a window where a failed move loses
    /// both copies: the original is already gone, and the caller's recovery
    /// disposes of the staged one. Another process claiming the freed name, or
    /// the parent turning read-only, is enough. Moving the existing item aside
    /// instead means every failure path still has it to put back.
    static func swapIntoPlace(staged: URL, destination: URL, fileManager fm: FileManager) throws {
        var wasDirectory: ObjCBool = false
        let existed = fm.fileExists(atPath: destination.path, isDirectory: &wasDirectory)

        // Where the existing item went, so it can come back if the swap fails.
        var movedAside: URL?
        var inTrash: NSURL?

        if existed {
            // A replaced folder goes to the Trash rather than being deleted: a
            // tree of files is not something to destroy on one confirmation,
            // and a replace is never recorded in the undo stack. Trashing it
            // directly keeps its own name, so it is findable. A single file is
            // moved aside and removed — a large copy would fill the Trash.
            if wasDirectory.boolValue, (try? fm.trashItem(at: destination, resultingItemURL: &inTrash)) != nil {
                // now in the Trash, under its own name
            } else {
                let aside = uniqueURL(
                    for: destination.deletingLastPathComponent()
                        .appendingPathComponent(".soquel-replaced-" + destination.lastPathComponent),
                    fileManager: fm
                )
                try fm.moveItem(at: destination, to: aside)
                movedAside = aside
            }
        }

        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            if let movedAside { try? fm.moveItem(at: movedAside, to: destination) }
            else if let recovered = inTrash as URL? { try? fm.moveItem(at: recovered, to: destination) }
            throw error
        }
        if let movedAside { try? fm.removeItem(at: movedAside) }
    }

    /// Stage beside the destination, then swap. A failure at any point leaves
    /// the existing item untouched.
    private func replaceItem(at destination: URL, with source: URL, move: Bool, fileManager fm: FileManager) throws {
        let directory = destination.deletingLastPathComponent()
        let staged = Self.uniqueURL(
            for: directory.appendingPathComponent(".soquel-incoming-" + source.lastPathComponent),
            fileManager: fm
        )
        do {
            if move { try fm.moveItem(at: source, to: staged) }
            else { try fm.copyItem(at: source, to: staged) }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try Self.swapIntoPlace(staged: staged, destination: destination, fileManager: fm)
        } catch {
            if move { try? fm.moveItem(at: staged, to: source) }
            else { try? fm.removeItem(at: staged) }
            throw error
        }
    }

    // MARK: - Trash

    func trash(_ urls: [URL], completion: @escaping (OperationResult) -> Void) {
        guard !urls.isEmpty else { return }
        begin("Moving \(urls.count) item(s) to Trash")

        queue.async {
            let fm = FileManager()
            var result = OperationResult()
            for url in urls {
                do {
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    result.succeeded.append(url)
                    if let inTrash = resulting as URL? {
                        result.trashedPairs.append((url, inTrash))
                    }
                } catch {
                    result.failures.append((url, error))
                }
            }
            DispatchQueue.main.async { self.end(); completion(result) }
        }
    }

    func deletePermanently(_ urls: [URL], completion: @escaping (OperationResult) -> Void) {
        guard !urls.isEmpty else { return }
        begin("Deleting \(urls.count) item(s)")

        queue.async {
            let fm = FileManager()
            var result = OperationResult()
            for url in urls {
                do {
                    try fm.removeItem(at: url)
                    result.succeeded.append(url)
                } catch {
                    result.failures.append((url, error))
                }
            }
            DispatchQueue.main.async { self.end(); completion(result) }
        }
    }

    // MARK: - Synchronous single-item actions

    func rename(_ url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard destination != url else { return url }
        let fm = FileManager.default
        // A case-only rename on a case-insensitive volume reports the
        // destination as existing — it is the file itself, and the move
        // handles it correctly. On a case-sensitive volume the same spelling
        // can be a second, distinct file, so the test is file identity, not
        // how the two names compare lowercased.
        if fm.fileExists(atPath: destination.path), !sameFile(url, destination) {
            throw SoquelError.nameInUse(newName)
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    func duplicate(_ urls: [URL]) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = url.deletingLastPathComponent()
                .appendingPathComponent(base + " copy")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            candidate = Self.uniqueURL(for: candidate, fileManager: fm)
            try fm.copyItem(at: url, to: candidate)
            created.append(candidate)
        }
        return created
    }

    func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SoquelError.nameInUse(name)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func createFile(named name: String, in directory: URL, contents: String = "") throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SoquelError.nameInUse(name)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)) else {
            throw SoquelError.createFailed(name)
        }
        // A shell script that is not executable is a shell script you cannot run.
        if url.pathExtension == "sh" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    /// A real POSIX symlink, not a Finder alias.
    ///
    /// The two look alike and behave differently: `ln -s` links read as aliases
    /// in Finder, Finder aliases are invisible to the shell, and Finder's own
    /// menu makes an alias when what was wanted was a symlink.
    ///
    /// The link is relative when both ends share a parent, so moving or
    /// renaming the folder holding them does not break it.
    @discardableResult
    func createSymlink(to target: URL, in directory: URL, named name: String? = nil) throws -> URL {
        let linkName = name ?? target.lastPathComponent
        let link = directory.appendingPathComponent(linkName)
        guard !FileManager.default.fileExists(atPath: link.path) else {
            throw SoquelError.nameInUse(linkName)
        }
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: Self.linkDestination(to: target, from: directory)
        )
        return link
    }

    /// Relative when the target sits beside the link, absolute otherwise.
    static func linkDestination(to target: URL, from directory: URL) -> String {
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        if resolvedTarget.deletingLastPathComponent() == resolvedDirectory {
            return resolvedTarget.lastPathComponent
        }
        return resolvedTarget.path
    }

    // MARK: - Helpers

    /// Appends " 2", " 3", … before the extension until the name is free.
    static func uniqueURL(for url: URL, fileManager fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
            if n > 9999 { return candidate }
        }
    }
}

enum SoquelError: LocalizedError {
    case nameInUse(String)
    case createFailed(String)
    case invalidName(String)
    case destinationInsideSource(String)
    case appNotFound(String)

    var errorDescription: String? {
        switch self {
        case .nameInUse(let n): return "An item named “\(n)” already exists in this folder."
        case .createFailed(let n): return "Could not create “\(n)”."
        case .invalidName(let n): return "“\(n)” is not a valid name."
        case .destinationInsideSource(let n): return "“\(n)” cannot be copied into itself."
        case .appNotFound(let n): return "“\(n)” is not installed."
        }
    }
}

/// True when both URLs resolve to one file on disk, by identity rather than
/// spelling. This is how a case-only rename is told apart from a collision:
/// on a case-insensitive volume "README.txt" resolves to "readme.txt" itself,
/// while on a case-sensitive volume the two names can be two distinct files.
/// False when either side cannot report an identifier — a claim of sameness
/// needs evidence from both ends.
func sameFile(_ a: URL, _ b: URL) -> Bool {
    let key: URLResourceKey = .fileResourceIdentifierKey
    guard let idA = (try? a.resourceValues(forKeys: [key]))?.fileResourceIdentifier,
          let idB = (try? b.resourceValues(forKeys: [key]))?.fileResourceIdentifier
    else { return false }
    return idA.isEqual(idB)
}

/// True when both URLs name the same file on disk. Compares resolved paths so a
/// symlinked parent (/tmp against /private/tmp) does not read as two locations.
func samePath(_ a: URL, _ b: URL) -> Bool {
    a.resolvingSymlinksInPath().standardizedFileURL.path
        == b.resolvingSymlinksInPath().standardizedFileURL.path
}

/// True when `candidate` sits inside `ancestor`.
func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
    let child = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let parent = ancestor.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard child.count > parent.count else { return false }
    return Array(child.prefix(parent.count)) == parent
}

func validateFileName(_ name: String) -> SoquelError? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .invalidName(name) }
    if trimmed.contains("/") || trimmed.contains(":") { return .invalidName(name) }
    if trimmed == "." || trimmed == ".." { return .invalidName(name) }
    return nil
}

/// A starting point for a new file. Deliberately a short list of things people
/// actually make by hand — not every type the system knows about.
struct FileTemplate {
    let id: String
    let title: String
    let defaultName: String
    let contents: String

    static let all: [FileTemplate] = [
        FileTemplate(id: "txt", title: "Text File", defaultName: "untitled.txt", contents: ""),
        FileTemplate(id: "md", title: "Markdown", defaultName: "untitled.md", contents: "# \n"),
        FileTemplate(id: "json", title: "JSON", defaultName: "untitled.json", contents: "{\n}\n"),
        FileTemplate(id: "swift", title: "Swift", defaultName: "untitled.swift", contents: "import Foundation\n\n"),
        FileTemplate(id: "py", title: "Python", defaultName: "untitled.py", contents: ""),
        FileTemplate(id: "sh", title: "Shell Script", defaultName: "untitled.sh", contents: "#!/usr/bin/env bash\nset -euo pipefail\n\n"),
        FileTemplate(id: "html", title: "HTML", defaultName: "untitled.html", contents: "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n</body>\n</html>\n"),
        FileTemplate(id: "csv", title: "CSV", defaultName: "untitled.csv", contents: ""),
    ]
}
