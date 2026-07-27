import XCTest
@testable import SoquelCore

final class DiskMapScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-diskmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ bytes: Int, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func scan(_ url: URL) throws -> DiskMap.Node {
        let map = DiskMap()
        var result: DiskMap.Node?
        let done = expectation(description: "scan finished")
        map.scan(url, progress: { _ in }, finished: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result)
    }

    private func child(_ node: DiskMap.Node, _ name: String) -> DiskMap.Node? {
        node.children.first { $0.name == name }
    }

    func testAFolderAddsUpItsChildren() throws {
        try write(40_000, "a.bin")
        try write(20_000, "b.bin")
        let node = try scan(root)

        XCTAssertTrue(node.isDirectory)
        XCTAssertEqual(node.fileCount, 2)
        // Allocated size rounds up to block size, so this checks the ordering
        // and a sane floor rather than an exact byte count.
        XCTAssertGreaterThanOrEqual(node.bytes, 60_000)
    }

    func testChildrenAreLargestFirst() throws {
        try write(10_000, "small.bin")
        try write(90_000, "big.bin")
        try write(50_000, "middle.bin")
        let node = try scan(root)
        XCTAssertEqual(node.children.map(\.name), ["big.bin", "middle.bin", "small.bin"])
    }

    func testNestedFoldersRollUp() throws {
        try write(30_000, "deep/nested/thing.bin")
        let node = try scan(root)
        let deep = try XCTUnwrap(child(node, "deep"))
        XCTAssertGreaterThanOrEqual(deep.bytes, 30_000)
        XCTAssertEqual(deep.fileCount, 1)
        XCTAssertEqual(node.bytes, deep.bytes)
    }

    /// A link to a parent folder would make the walk run forever.
    func testSymlinksAreNotFollowed() throws {
        try write(10_000, "real/file.bin")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )
        let node = try scan(root)
        XCTAssertNil(child(node, "loop"))
        XCTAssertEqual(node.fileCount, 1)
    }

    /// Finder counts a hard link as another copy; this counts the inode once.
    func testHardLinksAreCountedOnce() throws {
        let original = try write(50_000, "original.bin")
        try FileManager.default.linkItem(
            at: original, to: root.appendingPathComponent("alias.bin")
        )
        let node = try scan(root)

        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.fileCount, 2)
        // Both names appear, but the bytes are only counted for one of them.
        XCTAssertLessThan(node.bytes, 100_000)
        XCTAssertGreaterThanOrEqual(node.bytes, 50_000)
    }

    func testAnEmptyFolderScansToZero() throws {
        let node = try scan(root)
        XCTAssertEqual(node.bytes, 0)
        XCTAssertEqual(node.fileCount, 0)
        XCTAssertTrue(node.children.isEmpty)
    }

    func testAncestryWalksBackToTheRoot() throws {
        try write(1_000, "one/two/three.bin")
        let node = try scan(root)
        let three = try XCTUnwrap(child(child(child(node, "one")!, "two")!, "three.bin"))
        XCTAssertEqual(three.ancestry.map(\.name), [node.name, "one", "two", "three.bin"])
        XCTAssertEqual(three.depth, 3)
    }

    func testCancellingReturnsNothing() throws {
        for index in 0..<200 { try write(1_000, "file\(index).bin") }
        let map = DiskMap()
        var result: DiskMap.Node?
        let done = expectation(description: "cancelled")
        map.scan(root, progress: { _ in }, finished: { result = $0; done.fulfill() })
        map.cancel()
        wait(for: [done], timeout: 30)
        XCTAssertNil(result)
    }
}

final class SunburstLayoutTests: XCTestCase {
    private func node(_ name: String, _ bytes: Int64, _ children: [DiskMap.Node] = []) -> DiskMap.Node {
        DiskMap.Node(
            url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
            isDirectory: !children.isEmpty, bytes: bytes, fileCount: 1, children: children
        )
    }

    func testTheRootIsOneFullCircleAtTheCentre() {
        let segments = SunburstLayout.segments(for: node("root", 100), rings: 3)
        let root = segments.first { $0.ring == 0 }
        XCTAssertEqual(root?.start, 0)
        XCTAssertEqual(root?.end ?? 0, 2 * .pi, accuracy: 0.0001)
    }

    func testChildAnglesAreProportionalToSize() {
        let tree = node("root", 100, [node("big", 75), node("small", 25)])
        let segments = SunburstLayout.segments(for: tree, rings: 3)

        let big = segments.first { $0.name == "big" }
        let small = segments.first { $0.name == "small" }
        XCTAssertEqual(big?.sweep ?? 0, 2 * .pi * 0.75, accuracy: 0.0001)
        XCTAssertEqual(small?.sweep ?? 0, 2 * .pi * 0.25, accuracy: 0.0001)
    }

    func testChildrenTileTheirParentWithoutGaps() {
        let tree = node("root", 100, [node("a", 50), node("b", 30), node("c", 20)])
        let ring = SunburstLayout.segments(for: tree, rings: 3)
            .filter { $0.ring == 1 }
            .sorted { $0.start < $1.start }

        XCTAssertEqual(ring.first?.start, 0)
        XCTAssertEqual(ring.last?.end ?? 0, 2 * .pi, accuracy: 0.0001)
        for (left, right) in zip(ring, ring.dropFirst()) {
            XCTAssertEqual(left.end, right.start, accuracy: 0.0001)
        }
    }

    func testRingsStopAtTheLimit() {
        let deep = node("root", 100, [node("a", 100, [node("b", 100, [node("c", 100)])])])
        let segments = SunburstLayout.segments(for: deep, rings: 2)
        XCTAssertTrue(segments.allSatisfy { $0.ring <= 2 })
    }

    /// A slice too thin to see must not silently vanish from the total, or the
    /// picture stops adding up to the disk.
    func testSliversAreCombinedRatherThanDropped() {
        var children = [node("big", 1_000)]
        for index in 0..<500 { children.append(node("tiny\(index)", 1)) }
        let tree = node("root", 1_500, children)

        let ring = SunburstLayout.segments(for: tree, rings: 2).filter { $0.ring == 1 }
        XCTAssertTrue(ring.contains { $0.name == "smaller items" })

        let total = ring.reduce(0.0) { $0 + $1.sweep }
        XCTAssertEqual(total, 2 * .pi, accuracy: 0.0001)
    }

    func testAnEmptyFolderProducesOnlyTheCentre() {
        let segments = SunburstLayout.segments(for: node("root", 0), rings: 3)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.ring, 0)
    }

    // MARK: - Hit testing

    private var tiled: [SunburstSegment] {
        SunburstLayout.segments(
            for: node("root", 100, [node("a", 50), node("b", 50)]), rings: 3
        )
    }

    func testTheCentreHoleIsNotASegment() {
        let hit = SunburstLayout.segment(
            at: CGPoint(x: 100, y: 100), centre: CGPoint(x: 100, y: 100),
            ringWidth: 20, holeRadius: 30, segments: tiled
        )
        XCTAssertNil(hit)
    }

    /// Twelve o'clock is the start of the first child; three o'clock is halfway
    /// round, which is the second when the two are equal.
    func testAnglesMapToTheRightWedge() {
        let centre = CGPoint(x: 100, y: 100)
        let above = CGPoint(x: 100, y: 145)      // straight up
        let right = CGPoint(x: 145, y: 100)      // quarter turn clockwise

        XCTAssertEqual(
            SunburstLayout.segment(at: above, centre: centre, ringWidth: 20,
                                   holeRadius: 30, segments: tiled)?.name,
            "a"
        )
        XCTAssertEqual(
            SunburstLayout.segment(at: right, centre: centre, ringWidth: 20,
                                   holeRadius: 30, segments: tiled)?.name,
            "a"
        )
        let below = CGPoint(x: 100, y: 55)       // half turn
        XCTAssertEqual(
            SunburstLayout.segment(at: below, centre: centre, ringWidth: 20,
                                   holeRadius: 30, segments: tiled)?.name,
            "b"
        )
    }

    func testPointsBeyondTheRingsHitNothing() {
        let hit = SunburstLayout.segment(
            at: CGPoint(x: 900, y: 100), centre: CGPoint(x: 100, y: 100),
            ringWidth: 20, holeRadius: 30, segments: tiled
        )
        XCTAssertNil(hit)
    }
}
