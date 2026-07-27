import Foundation

/// Comparing two folder trees, and copying the differences between them.
///
/// This is `rsync -n` with a list you can read: it says what is on the left
/// only, on the right only, and what exists in both but differs — then copies
/// only what you pick.
enum FolderCompare {
    /// How two files that exist on both sides are judged the same.
    enum Precision: String, Codable {
        /// Size and modification date, which is what rsync does by default.
        case quick
        /// SHA-256 of the contents. Correct, and reads every byte of both sides.
        case checksum
    }

    enum Status: String {
        case onlyLeft
        case onlyRight
        case identical
        case differs
        /// A folder on one side and a file on the other.
        case typeConflict

        var label: String {
            switch self {
            case .onlyLeft: return "Left only"
            case .onlyRight: return "Right only"
            case .identical: return "Same"
            case .differs: return "Differs"
            case .typeConflict: return "Type conflict"
            }
        }

        var isDifference: Bool { self != .identical }
    }

    struct Side {
        let url: URL
        let size: Int64
        let modified: Date
        let isDirectory: Bool
    }

    struct Entry {
        /// Path relative to the two roots, which is what makes the two sides
        /// comparable at all.
        let relativePath: String
        let left: Side?
        let right: Side?
        let status: Status

        var name: String { (relativePath as NSString).lastPathComponent }
    }

    struct Summary {
        var onlyLeft = 0
        var onlyRight = 0
        var differs = 0
        var identical = 0
        var typeConflicts = 0

        var differenceCount: Int { onlyLeft + onlyRight + differs + typeConflicts }
    }

    // MARK: - Comparing

    /// Walks both trees and pairs entries by relative path.
    ///
    /// Symlinks are compared as links, not followed: following them would let a
    /// link to a parent folder produce an unbounded walk, and would report a
    /// file as present on both sides when only the link is.
    static func compare(
        left leftRoot: URL,
        right rightRoot: URL,
        precision: Precision = .quick,
        includeHidden: Bool = true,
        isCancelled: () -> Bool = { false }
    ) -> [Entry] {
        let leftSides = walk(leftRoot, includeHidden: includeHidden, isCancelled: isCancelled)
        let rightSides = walk(rightRoot, includeHidden: includeHidden, isCancelled: isCancelled)

        var entries: [Entry] = []
        entries.reserveCapacity(max(leftSides.count, rightSides.count))

        for path in Set(leftSides.keys).union(rightSides.keys).sorted() {
            if isCancelled() { return entries }
            let left = leftSides[path]
            let right = rightSides[path]
            entries.append(
                Entry(relativePath: path, left: left, right: right,
                      status: status(left: left, right: right, precision: precision))
            )
        }
        return entries
    }

    private static func status(left: Side?, right: Side?, precision: Precision) -> Status {
        switch (left, right) {
        case (nil, nil): return .identical      // unreachable; both keys came from a walk
        case (_, nil): return .onlyLeft
        case (nil, _): return .onlyRight
        case let (left?, right?):
            if left.isDirectory != right.isDirectory { return .typeConflict }
            // Two folders with the same path are the same folder; their contents
            // are compared as their own entries.
            if left.isDirectory { return .identical }
            switch precision {
            case .quick:
                let sameSize = left.size == right.size
                // Filesystem timestamps differ in sub-second precision across
                // volumes, so a whole second is the tolerance.
                let sameTime = abs(left.modified.timeIntervalSince(right.modified)) < 1
                return sameSize && sameTime ? .identical : .differs
            case .checksum:
                guard left.size == right.size else { return .differs }
                guard let leftSum = Checksum.sha256(of: left.url),
                      let rightSum = Checksum.sha256(of: right.url)
                else { return .differs }
                return leftSum == rightSum ? .identical : .differs
            }
        }
    }

    /// relative path → what is there.
    private static func walk(
        _ root: URL, includeHidden: Bool, isCancelled: () -> Bool
    ) -> [String: Side] {
        var result: [String: Side] = [:]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: options
        ) else { return result }

        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            if isCancelled() { return result }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard !relative.isEmpty else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            result[relative] = Side(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                isDirectory: values?.isDirectory ?? false
            )
        }
        return result
    }

    static func summarize(_ entries: [Entry]) -> Summary {
        var summary = Summary()
        for entry in entries {
            switch entry.status {
            case .onlyLeft: summary.onlyLeft += 1
            case .onlyRight: summary.onlyRight += 1
            case .differs: summary.differs += 1
            case .identical: summary.identical += 1
            case .typeConflict: summary.typeConflicts += 1
            }
        }
        return summary
    }

    // MARK: - Synchronising

    enum Direction {
        case leftToRight
        case rightToLeft

        var label: String {
            self == .leftToRight ? "Copy to the right" : "Copy to the left"
        }
    }

    /// One copy to perform: an existing file and where it should end up.
    struct Plan {
        let source: URL
        let destination: URL
        let relativePath: String
        /// True when something is already at the destination and will be replaced.
        let overwrites: Bool
    }

    /// Turns chosen entries into copies. Entries with nothing to copy in the
    /// requested direction are skipped rather than guessed at: copying the
    /// right-hand file when the left is missing would be a deletion in
    /// disguise, and that is the caller's decision, not this function's.
    static func plan(
        _ entries: [Entry], direction: Direction, left leftRoot: URL, right rightRoot: URL
    ) -> [Plan] {
        entries.compactMap { entry in
            let source = direction == .leftToRight ? entry.left : entry.right
            let other = direction == .leftToRight ? entry.right : entry.left
            guard let source, !source.isDirectory else { return nil }

            let destinationRoot = direction == .leftToRight ? rightRoot : leftRoot
            return Plan(
                source: source.url,
                destination: destinationRoot.appendingPathComponent(entry.relativePath),
                relativePath: entry.relativePath,
                overwrites: other != nil
            )
        }
    }

    /// Runs a plan. Parent folders are created as needed; an existing file is
    /// replaced only where the plan said it would be.
    @discardableResult
    static func apply(_ plans: [Plan]) throws -> Int {
        let manager = FileManager.default
        var copied = 0
        for plan in plans {
            let parent = plan.destination.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            if manager.fileExists(atPath: plan.destination.path) {
                _ = try manager.replaceItemAt(plan.destination, withItemAt: copyToStaging(plan.source))
            } else {
                try manager.copyItem(at: plan.source, to: plan.destination)
            }
            copied += 1
        }
        return copied
    }

    /// `replaceItemAt` consumes the item it is given, so it must never be
    /// handed the source file itself — that would move the original out of the
    /// folder being copied from.
    private static func copyToStaging(_ source: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
}
