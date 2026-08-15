import Foundation

/// A scan of what is taking up the space, as a tree of sizes.
///
/// The point of a picture over a sorted list is that a list of the largest
/// *files* misses the case that actually fills a disk: ten thousand small
/// things in one folder. An area proportional to size shows that as one fat
/// wedge, which is the whole reason this exists.
final class DiskMap {
    /// One folder or file, with everything under it already added up.
    final class Node {
        let url: URL
        let name: String
        let isDirectory: Bool
        private(set) var bytes: Int64
        private(set) var fileCount: Int
        /// How many items at or under here had no readable size.
        ///
        /// Unreadable items used to be dropped from the tree or charged zero
        /// bytes, which is the one answer that is never right. On macOS every
        /// TCC-protected location under the home folder — ~/Library/Mail,
        /// ~/Library/Messages, Photos libraries, local Time Machine snapshots —
        /// refuses to open without Full Disk Access, so scanning ~/ reported
        /// 40 GB of a 200 GB home folder and drew the folders that did open as
        /// proportionally huge. Counting the misses is what lets the panel say
        /// the total is a floor rather than offering it as the answer.
        private(set) var unreadableCount: Int
        /// Largest first, which is the order the drawing wants.
        private(set) var children: [Node]
        weak var parent: Node?

        init(url: URL, name: String, isDirectory: Bool, bytes: Int64,
             fileCount: Int, unreadableCount: Int = 0, children: [Node] = []) {
            self.url = url
            self.name = name
            self.isDirectory = isDirectory
            self.bytes = bytes
            self.fileCount = fileCount
            self.unreadableCount = unreadableCount
            self.children = children
            for child in children { child.parent = self }
        }

        /// The chain from the root down to here, for the breadcrumb.
        var ancestry: [Node] {
            var chain: [Node] = [self]
            var current = self
            while let next = current.parent {
                chain.append(next)
                current = next
            }
            return chain.reversed()
        }

        var depth: Int { (parent?.depth ?? -1) + 1 }

        /// The names from the scan root down to here.
        ///
        /// A rescan builds an entirely new tree, so nothing can hold on to a
        /// node across one. Holding on to the trail and following it back down
        /// is how the panel keeps its place.
        var trail: [String] { ancestry.dropFirst().map(\.name) }

        /// Follows `trail` down from here as far as it still goes.
        ///
        /// Stops at the deepest folder that survived, so trashing the folder
        /// that was on screen lands on its parent rather than back at the root.
        /// Sibling names are unique within a folder, so the walk is exact.
        func descendant(along trail: [String]) -> Node {
            var node = self
            for name in trail {
                guard let next = node.children.first(where: { $0.name == name }) else { break }
                node = next
            }
            return node
        }

        /// Share of the parent, 0 when the parent is empty.
        var fractionOfParent: Double {
            guard let parent, parent.bytes > 0 else { return 1 }
            return Double(bytes) / Double(parent.bytes)
        }
    }

    struct Progress {
        let scanned: Int
        let bytes: Int64
        let currentPath: String
    }

    private let queue = DispatchQueue(label: "app.soquel.diskmap", qos: .utility)

    /// Which walk is the live one.
    ///
    /// A plain `cancelled` flag that `scan` reset could resurrect a walk that
    /// had been cancelled but had not yet noticed: close the panel mid-scan,
    /// reopen it on another folder, and the first walk ran to completion with
    /// the flag cleared, delivering the *old* folder's tree into the panel and
    /// leaving it looking finished while the new scan had not begun. Starting
    /// and cancelling both move the generation on, so a walk can tell whether
    /// it is still the one being waited for and no reset can undo a cancel.
    private let lock = NSLock()
    private var generation = 0
    /// The generation of the most recent `scan`. `cancel` moves `generation`
    /// on without touching this, which separates "stop, and tell me" from
    /// "forget this, another scan has started".
    private var lastStarted = 0

    /// Stops the walk. Safe to call from the main thread mid-scan.
    func cancel() {
        lock.lock(); generation += 1; lock.unlock()
    }

    /// Whether this walk should still be walking.
    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    /// Whether this walk's tree is still wanted. A scan replaced by a newer
    /// one reports nothing: delivering its tree put the previous folder back
    /// into the panel and left it looking finished.
    private func shouldDeliver(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == lastStarted
    }

    /// Scans `root`. `progress` and `finished` are called on the main queue;
    /// `finished` gets nil if the scan was cancelled.
    func scan(
        _ root: URL,
        progress: @escaping (Progress) -> Void,
        finished: @escaping (Node?) -> Void
    ) {
        lock.lock()
        generation += 1
        lastStarted = generation
        let token = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            // A superseded walk bails at its next check rather than holding
            // the serial queue while the one that replaced it waits.
            guard self.isCurrent(token) else {
                if self.shouldDeliver(token) { DispatchQueue.main.async { finished(nil) } }
                return
            }
            var seenInodes = Set<UInt64>()
            var scanned = 0
            var totalBytes: Int64 = 0
            var lastReport = 0

            let node = self.walk(root, token: token, seenInodes: &seenInodes,
                                 scanned: &scanned, totalBytes: &totalBytes) { count, bytes, path in
                // Reporting every file would spend more time on the main queue
                // than on the disk.
                guard count - lastReport >= 500 else { return }
                lastReport = count
                DispatchQueue.main.async {
                    progress(Progress(scanned: count, bytes: bytes, currentPath: path))
                }
            }

            let stopped = !self.isCurrent(token)
            guard self.shouldDeliver(token) else { return }
            DispatchQueue.main.async {
                if stopped {
                    Log.info(.scan, "Disk scan of \(root.path) cancelled after \(scanned) items")
                } else {
                    let unreadable = node?.unreadableCount ?? 0
                    Log.info(.scan, "Disk scan of \(root.path): \(scanned) items, "
                        + "\(node?.bytes ?? 0) bytes"
                        + (unreadable > 0 ? ", \(unreadable) unreadable" : ""))
                }
                finished(stopped ? nil : node)
            }
        }
    }

    /// Depth-first, adding allocated sizes.
    ///
    /// Symlinks are not followed — a link to a parent folder would never
    /// terminate — and a hard-linked inode counts once, which is where
    /// Finder's own numbers go wrong.
    ///
    /// Anything that cannot be read still comes back as a node, carrying zero
    /// bytes and an unreadable count of one. It used to come back as nil, or as
    /// an empty folder, so the picture lost it without saying so.
    ///
    /// The bytes handed to `report` are the running total across the whole
    /// walk. The panel shows the figure as "so far", so one file's size or one
    /// subtree's subtotal there was simply the wrong number.
    private func walk(
        _ url: URL,
        token: Int,
        seenInodes: inout Set<UInt64>,
        scanned: inout Int,
        totalBytes: inout Int64,
        report: (Int, Int64, String) -> Void
    ) -> Node? {
        if !isCurrent(token) { return nil }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .fileResourceIdentifierKey,
        ]
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Not even whether it is a folder is known, so it is charged
            // nothing and counted as a miss.
            return Node(url: url, name: name, isDirectory: false, bytes: 0,
                        fileCount: 0, unreadableCount: 1)
        }
        if values.isSymbolicLink == true { return nil }

        if values.isDirectory != true {
            // A file already counted under another name is real, but its bytes
            // are not a second copy.
            if let identifier = values.fileResourceIdentifier as? Data {
                let hash = UInt64(identifier.hashValue.magnitude)
                guard seenInodes.insert(hash).inserted else {
                    return Node(url: url, name: name, isDirectory: false, bytes: 0, fileCount: 1)
                }
            }
            // Allocated size only. `fileSize` is the logical length, which
            // charges a sparse file allocating 4 KB for its whole 10 GB extent,
            // and it used to stand in whenever the allocated size was missing.
            // With no allocated size the size is simply unknown, which is not
            // the same as zero.
            guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                return Node(url: url, name: name, isDirectory: false, bytes: 0,
                            fileCount: 1, unreadableCount: 1)
            }
            let bytes = Int64(allocated)
            scanned += 1
            totalBytes += bytes
            report(scanned, totalBytes, url.path)
            return Node(url: url, name: name, isDirectory: false, bytes: bytes, fileCount: 1)
        }

        var unreadable = 0
        var contents: [URL] = []
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            // A folder that will not open is not an empty folder. Folding the
            // failure into `?? []` made the two indistinguishable, which is how
            // a permission-denied ~/Library/Mail came out as 0 bytes.
            unreadable = 1
        }

        var children: [Node] = []
        var total: Int64 = 0
        var files = 0
        for child in contents {
            if !isCurrent(token) { return nil }
            guard let node = walk(child, token: token, seenInodes: &seenInodes,
                                  scanned: &scanned, totalBytes: &totalBytes, report: report)
            else { continue }
            total += node.bytes
            files += node.fileCount
            unreadable += node.unreadableCount
            children.append(node)
        }

        children.sort { $0.bytes > $1.bytes }
        report(scanned, totalBytes, url.path)
        return Node(url: url, name: name, isDirectory: true, bytes: total,
                    fileCount: files, unreadableCount: unreadable, children: children)
    }
}

// MARK: - Ring layout

/// One drawn wedge: which node, which ring, and the angles it spans.
struct SunburstSegment: Equatable {
    let url: URL
    let name: String
    let bytes: Int64
    let isDirectory: Bool
    /// 0 is the centre disc, 1 the first ring outwards.
    let ring: Int
    /// Radians, clockwise from twelve o'clock.
    let start: Double
    let end: Double
    /// True for the combined "smaller items" wedge, which stands for a set of
    /// children rather than for anything on disk.
    ///
    /// Consumers used to recognise it by comparing `name` against "smaller
    /// items", so a folder actually called that could not be opened by click
    /// and its right-click menu never appeared. Worse, the name is all that
    /// stopped a Move to Trash on the aggregate deleting the parent folder,
    /// whose URL it carries.
    let isAggregate: Bool

    init(url: URL, name: String, bytes: Int64, isDirectory: Bool, ring: Int,
         start: Double, end: Double, isAggregate: Bool = false) {
        self.url = url
        self.name = name
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.ring = ring
        self.start = start
        self.end = end
        self.isAggregate = isAggregate
    }

    var sweep: Double { end - start }

    func contains(angle: Double) -> Bool { angle >= start && angle < end }
}

enum SunburstLayout {
    /// Wedges narrower than this are not drawn: below roughly a degree they
    /// are a hairline nobody can point at, and drawing tens of thousands of
    /// them is what makes these views crawl.
    static let minimumSweep = Double.pi / 180

    /// Turns a tree into wedges, outwards from `root`.
    ///
    /// Everything too small to draw in a ring is added up into one "smaller
    /// items" wedge, so the ring still adds up to its parent and the picture
    /// does not quietly lose a third of the disk.
    static func segments(for root: DiskMap.Node, rings: Int) -> [SunburstSegment] {
        var result: [SunburstSegment] = []
        add(root, ring: 0, start: 0, end: 2 * .pi, rings: rings, into: &result)
        return result
    }

    private static func add(
        _ node: DiskMap.Node, ring: Int, start: Double, end: Double,
        rings: Int, into result: inout [SunburstSegment]
    ) {
        result.append(SunburstSegment(
            url: node.url, name: node.name, bytes: node.bytes,
            isDirectory: node.isDirectory, ring: ring, start: start, end: end
        ))
        guard ring < rings, node.bytes > 0, !node.children.isEmpty else { return }

        let span = end - start
        var cursor = start
        var hidden: Int64 = 0

        for child in node.children {
            let sweep = span * Double(child.bytes) / Double(node.bytes)
            if sweep < minimumSweep {
                hidden += child.bytes
                continue
            }
            add(child, ring: ring + 1, start: cursor, end: cursor + sweep, rings: rings, into: &result)
            cursor += sweep
        }

        // The remainder as one wedge, so the ring still accounts for the parent.
        if hidden > 0 {
            let sweep = span * Double(hidden) / Double(node.bytes)
            if sweep > 0 {
                result.append(SunburstSegment(
                    url: node.url, name: "smaller items", bytes: hidden,
                    isDirectory: true, ring: ring + 1, start: cursor, end: cursor + sweep,
                    isAggregate: true
                ))
            }
        }
    }

    /// The segment under a point, given the centre and the width of a ring.
    /// Returns nil for the middle and for anything past the outermost ring.
    static func segment(
        at point: CGPoint, centre: CGPoint, ringWidth: CGFloat,
        holeRadius: CGFloat, segments: [SunburstSegment]
    ) -> SunburstSegment? {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > holeRadius else { return nil }

        let ring = Int((distance - holeRadius) / ringWidth) + 1
        // atan2 gives counter-clockwise from three o'clock; the rings run
        // clockwise from twelve.
        var angle = Double.pi / 2 - atan2(Double(dy), Double(dx))
        if angle < 0 { angle += 2 * .pi }

        return segments.first { $0.ring == ring && $0.contains(angle: angle) }
    }
}
