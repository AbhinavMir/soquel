import Foundation

/// Checksumming both ends of a copy.
///
/// macOS transfers the data and assumes it worked. Usually it did. On a long
/// haul to a network share or an external disk it sometimes did not, and
/// nothing tells you.
enum VerifiedCopy {
    /// Off by default: hashing both ends reads every byte twice, which is not
    /// a cost to impose on someone dragging a file across a folder.
    static var isEnabled: Bool {
        get { Settings.object(forKey: "verifyTransfers") as? Bool ?? false }
        set { Settings.set(newValue, forKey: "verifyTransfers") }
    }

    enum Outcome: String {
        case passed
        case failed
        /// Could not be read at one end or the other, so nothing is claimed.
        case unreadable
    }

    struct Entry {
        let source: URL
        let destination: URL
        let outcome: Outcome
        let sourceHash: String?
        let destinationHash: String?
    }

    struct Manifest {
        var entries: [Entry] = []

        var passed: Int { entries.filter { $0.outcome == .passed }.count }
        var failed: [Entry] { entries.filter { $0.outcome == .failed } }
        var unreadable: [Entry] { entries.filter { $0.outcome == .unreadable } }
        var isClean: Bool { failed.isEmpty && unreadable.isEmpty }

        var summary: String {
            guard !entries.isEmpty else { return "Nothing verified" }
            if isClean { return "\(passed) of \(entries.count) verified" }
            var parts = ["\(passed) of \(entries.count) verified"]
            if !failed.isEmpty { parts.append("\(failed.count) did not match") }
            if !unreadable.isEmpty { parts.append("\(unreadable.count) unreadable") }
            return parts.joined(separator: ", ")
        }

        /// Plain text, for pasting into wherever the job is being tracked.
        var text: String {
            entries.map { entry in
                "\(entry.outcome.rawValue.uppercased())  \(entry.source.path) -> \(entry.destination.path)"
            }.joined(separator: "\n")
        }
    }

    /// Compares one pair. A directory verifies by walking it.
    static func verify(
        source: URL, destination: URL, hash: (URL) -> String? = Checksum.sha256(of:)
    ) -> Entry {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return verifyTree(source: source, destination: destination, hash: hash)
        }

        guard let a = hash(source) else {
            return Entry(source: source, destination: destination,
                         outcome: .unreadable, sourceHash: nil, destinationHash: nil)
        }
        guard let b = hash(destination) else {
            return Entry(source: source, destination: destination,
                         outcome: .unreadable, sourceHash: a, destinationHash: nil)
        }
        return Entry(source: source, destination: destination,
                     outcome: a == b ? .passed : .failed, sourceHash: a, destinationHash: b)
    }

    /// A folder passes when every file under it matches and neither side has a
    /// file the other does not.
    static func verifyTree(
        source: URL, destination: URL, hash: (URL) -> String? = Checksum.sha256(of:)
    ) -> Entry {
        guard let left = relativeFiles(under: source), let right = relativeFiles(under: destination) else {
            return Entry(source: source, destination: destination,
                         outcome: .unreadable, sourceHash: nil, destinationHash: nil)
        }
        guard left == right else {
            return Entry(source: source, destination: destination,
                         outcome: .failed, sourceHash: nil, destinationHash: nil)
        }

        for relative in left.sorted() {
            let entry = verify(
                source: source.appendingPathComponent(relative),
                destination: destination.appendingPathComponent(relative),
                hash: hash
            )
            if entry.outcome != .passed {
                return Entry(source: source, destination: destination,
                             outcome: entry.outcome, sourceHash: nil, destinationHash: nil)
            }
        }
        return Entry(source: source, destination: destination,
                     outcome: .passed, sourceHash: nil, destinationHash: nil)
    }

    /// Every file under `root`, as paths relative to it. Symlinks are listed by
    /// name but not followed.
    static func relativeFiles(under root: URL) -> Set<String>? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { return nil }

        var names: Set<String> = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isDirectory == true { continue }
            guard let relative = relativePath(of: url, under: root) else { return nil }
            names.insert(relative)
        }
        return names
    }

    /// Verifies a whole result. Only what a copy actually created is checked —
    /// a move has nothing left at the source to compare against.
    static func verify(
        sources: [URL], destinations: [URL], hash: (URL) -> String? = Checksum.sha256(of:)
    ) -> Manifest {
        var manifest = Manifest()
        for (source, destination) in zip(sources, destinations) {
            manifest.entries.append(verify(source: source, destination: destination, hash: hash))
        }
        return manifest
    }
}
