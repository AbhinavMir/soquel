import AppKit

/// Session-scoped undo for file operations. Each entry knows how to reverse
/// itself; entries that cannot be reversed are never pushed.
final class UndoStack {
    static let shared = UndoStack()

    struct Entry {
        let label: String
        let revert: (@escaping (Error?) -> Void) -> Void
    }

    private var entries: [Entry] = []
    private let limit = 50

    var canUndo: Bool { !entries.isEmpty }
    var topLabel: String? { entries.last?.label }

    func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func undo(completion: @escaping (String?, Error?) -> Void) {
        guard let entry = entries.popLast() else { return completion(nil, nil) }
        entry.revert { error in completion(entry.label, error) }
    }

    // MARK: - Builders

    func pushRename(from oldURL: URL, to newURL: URL) {
        push(Entry(label: "Rename") { done in
            do {
                _ = try OperationEngine.shared.rename(newURL, to: oldURL.lastPathComponent)
                done(nil)
            } catch { done(error) }
        })
    }

    func pushCreated(_ urls: [URL], label: String) {
        guard !urls.isEmpty else { return }
        push(Entry(label: label) { done in
            OperationEngine.shared.trash(urls) { result in
                done(result.failures.first?.error)
            }
        })
    }

    /// Moves each item in the Trash back to where it came from.
    func pushTrash(_ pairs: [(original: URL, inTrash: URL)]) {
        guard !pairs.isEmpty else { return }
        push(Entry(label: "Move to Trash") { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager()
                var firstError: Error?
                for pair in pairs {
                    do {
                        try fm.moveItem(at: pair.inTrash, to: pair.original)
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                DispatchQueue.main.async { done(firstError) }
            }
        })
    }

    /// Undo of a copy trashes what the copy created. Destinations that
    /// overwrote an existing item are excluded: trashing them would remove the
    /// incoming file without restoring the one it replaced, leaving neither.
    func pushCopy(result: OperationResult) {
        // A merge cannot be undone: once two folders are combined there is no
        // record of which files were already there, so trashing the merged
        // folder would take the user's own files with it.
        guard result.mergedDestinations.isEmpty else { return }
        let replaced = Set(result.replacedDestinations)
        pushCreated(result.createdDestinations.filter { !replaced.contains($0) }, label: "Copy")
    }

    /// Undo of a move puts each destination back at its source path. Moves that
    /// overwrote an existing item are excluded for the same reason.
    func pushMove(result: OperationResult) {
        guard result.mergedDestinations.isEmpty else { return }
        let replaced = Set(result.replacedDestinations)
        let pairs = zip(result.succeeded, result.createdDestinations)
            .filter { !replaced.contains($0.1) }
        pushMove(sources: pairs.map(\.0), destinations: pairs.map(\.1))
    }

    func pushMove(sources: [URL], destinations: [URL]) {
        guard sources.count == destinations.count, !sources.isEmpty else { return }
        let pairs = Array(zip(destinations, sources))
        push(Entry(label: "Move") { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager()
                var firstError: Error?
                for (from, to) in pairs {
                    do {
                        try fm.moveItem(at: from, to: to)
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                DispatchQueue.main.async { done(firstError) }
            }
        })
    }
}
