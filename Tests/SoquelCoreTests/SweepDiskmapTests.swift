import XCTest
@testable import SoquelCore

/// Three ways the disk map told the user something untrue.
///
/// Items it could not read were charged zero bytes, so a home folder full of
/// TCC-protected locations came out at a fraction of its size with nothing
/// said. A rescan re-centred on the scan root, so trashing one file threw away
/// the drill-down that led to it. And the combined "smaller items" wedge was
/// recognised by comparing its name, so a folder genuinely called that was
/// treated as the sum rather than as a folder.
final class SweepDiskmapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sweep-diskmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

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

    private func child(_ node: DiskMap.Node?, _ name: String) -> DiskMap.Node? {
        node?.children.first { $0.name == name }
    }

    /// Takes every permission off a folder, which is how a TCC-protected
    /// location behaves for a scan without Full Disk Access: it can be seen in
    /// its parent's listing and stat'd, but not opened.
    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func node(_ name: String, _ bytes: Int64, _ children: [DiskMap.Node] = []) -> DiskMap.Node {
        DiskMap.Node(
            url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
            isDirectory: !children.isEmpty, bytes: bytes, fileCount: 1, children: children
        )
    }

    // MARK: - Unreadable items are counted, not charged zero

    /// A folder that will not open is not an empty folder. Folding the failure
    /// into `?? []` made the two the same thing on screen.
    func testAFolderThatWillNotOpenIsCountedRatherThanTreatedAsEmpty() throws {
        try XCTSkipIf(getuid() == 0, "root can read everything, so nothing comes back unreadable")
        try write(40_000, "open/big.bin")
        try write(40_000, "shut/big.bin")
        let shut = root.appendingPathComponent("shut")
        try lock(shut)
        defer { unlock(shut) }

        let node = try scan(root)
        let locked = try XCTUnwrap(child(node, "shut"))

        XCTAssertEqual(locked.unreadableCount, 1)
        XCTAssertEqual(locked.bytes, 0)
        XCTAssertEqual(node.unreadableCount, 1)
        // What could be read is still counted; it is the silence that was wrong.
        XCTAssertGreaterThanOrEqual(node.bytes, 40_000)
    }

    /// The count has to reach the root, since that is where the total someone
    /// is reading is shown.
    func testAnUnreadableFolderCountsAtEveryLevelAbove() throws {
        try XCTSkipIf(getuid() == 0, "root can read everything, so nothing comes back unreadable")
        try write(10_000, "a/b/c.bin")
        let deep = root.appendingPathComponent("a/b")
        try lock(deep)
        defer { unlock(deep) }

        let node = try scan(root)
        let a = try XCTUnwrap(child(node, "a"))
        let b = try XCTUnwrap(child(a, "b"))

        XCTAssertEqual(b.unreadableCount, 1)
        XCTAssertEqual(a.unreadableCount, 1)
        XCTAssertEqual(node.unreadableCount, 1)
        // Nothing under it could be added up, and a bare 0 is exactly the
        // number that used to be presented as the answer.
        XCTAssertEqual(node.bytes, 0)
    }

    func testAScanThatReadEverythingReportsNoMisses() throws {
        try write(10_000, "one.bin")
        try write(10_000, "two/three.bin")
        let node = try scan(root)
        XCTAssertEqual(node.unreadableCount, 0)
    }

    /// The panel has to say so, or the total still reads as the answer.
    func testTheSizeLineSaysWhenTheTotalIsOnlyAFloor() {
        let missed = DiskMap.Node(
            url: URL(fileURLWithPath: "/tmp/home"), name: "home", isDirectory: true,
            bytes: 40_000, fileCount: 12, unreadableCount: 3
        )
        let line = DiskMapPanelController.summary(for: missed)

        XCTAssertTrue(line.contains("12 files"), line)
        XCTAssertTrue(line.contains("3 items could not be read"), line)
        XCTAssertTrue(line.contains("minimum"), line)
    }

    func testOneMissedItemIsWordedSingly() {
        let missed = DiskMap.Node(
            url: URL(fileURLWithPath: "/tmp/home"), name: "home", isDirectory: true,
            bytes: 40_000, fileCount: 1, unreadableCount: 1
        )
        let line = DiskMapPanelController.summary(for: missed)

        XCTAssertTrue(line.contains("1 file "), line)
        XCTAssertTrue(line.contains("1 item could not be read"), line)
    }

    func testTheSizeLineIsUnchangedWhenEverythingWasRead() {
        let clean = DiskMap.Node(
            url: URL(fileURLWithPath: "/tmp/home"), name: "home", isDirectory: true,
            bytes: 40_000, fileCount: 12
        )
        let line = DiskMapPanelController.summary(for: clean)

        XCTAssertTrue(line.contains("12 files"), line)
        XCTAssertFalse(line.contains("could not be read"), line)
    }

    // MARK: - A rescan keeps its place

    func testTheTrailNamesEveryStepBelowTheRoot() throws {
        try write(1_000, "one/two/three.bin")
        let node = try scan(root)
        let two = try XCTUnwrap(child(child(node, "one"), "two"))

        XCTAssertEqual(two.trail, ["one", "two"])
        XCTAssertEqual(node.trail, [])
    }

    /// Trashing a file rescans, which builds a whole new tree. The drill-down
    /// used to be dropped at that point and the rings re-centred on the scan
    /// root; the trail is followed back down instead.
    func testARescanFollowsTheTrailBackDown() throws {
        try write(1_000, "one/two/three.bin")
        try write(1_000, "one/two/four.bin")
        let before = try scan(root)
        let two = try XCTUnwrap(child(child(before, "one"), "two"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("one/two/four.bin"))
        let after = try scan(root)
        let restored = after.descendant(along: two.trail)

        XCTAssertEqual(restored.name, "two")
        XCTAssertEqual(restored.url.path, two.url.path)
        XCTAssertEqual(restored.fileCount, 1)
    }

    /// The folder on screen can be the one that was just trashed, so the walk
    /// down stops at the deepest name still there.
    func testTheTrailStopsAtTheDeepestFolderThatSurvived() throws {
        try write(1_000, "one/two/three.bin")
        let before = try scan(root)
        let two = try XCTUnwrap(child(child(before, "one"), "two"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("one/two"))
        let after = try scan(root)

        XCTAssertEqual(after.descendant(along: two.trail).name, "one")
    }

    func testAnEmptyTrailStaysAtTheRoot() {
        let tree = node("root", 100, [node("a", 100)])
        XCTAssertEqual(tree.descendant(along: []).name, "root")
    }

    func testATrailIntoAFolderThatIsGoneStaysAtTheRoot() {
        let tree = node("root", 100, [node("a", 100)])
        XCTAssertEqual(tree.descendant(along: ["gone", "deeper"]).name, "root")
    }

    // MARK: - The combined wedge is flagged, not named

    /// Enough one-byte children that each is below `minimumSweep` and gets
    /// rolled into the aggregate.
    private var slivers: [DiskMap.Node] {
        (0..<500).map { node("tiny\($0)", 1) }
    }

    func testTheCombinedWedgeIsTheOnlyFlaggedOne() {
        let tree = node("root", 1_500, [node("big", 1_000)] + slivers)
        let ring = SunburstLayout.segments(for: tree, rings: 2).filter { $0.ring == 1 }
        let flagged = ring.filter(\.isAggregate)

        XCTAssertEqual(flagged.count, 1)
        XCTAssertEqual(flagged.first?.name, "smaller items")
        XCTAssertEqual(ring.first { $0.name == "big" }?.isAggregate, false)
    }

    /// The aggregate has no URL of its own so it carries the parent's, which is
    /// what makes the flag load-bearing: acting on this wedge acts on the whole
    /// folder it sits inside, Move to Trash included.
    func testTheCombinedWedgeCarriesItsParentsUrl() {
        let tree = node("root", 1_500, [node("big", 1_000)] + slivers)
        let ring = SunburstLayout.segments(for: tree, rings: 2).filter { $0.ring == 1 }

        XCTAssertEqual(ring.first(where: \.isAggregate)?.url.path, tree.url.path)
    }

    /// A folder genuinely called "smaller items" is a folder. Matching on the
    /// name meant it could not be opened by click and its right-click menu
    /// never appeared, so it had no Reveal and no Trash either.
    func testAFolderNamedSmallerItemsIsNotTheAggregate() {
        let real = node("smaller items", 500, [node("inside.bin", 500)])
        let tree = node("root", 2_000, [node("big", 1_000), real] + slivers)
        let ring = SunburstLayout.segments(for: tree, rings: 2).filter { $0.ring == 1 }

        let folder = ring.first { $0.name == "smaller items" && !$0.isAggregate }
        XCTAssertEqual(folder?.url.path, real.url.path)
        XCTAssertEqual(folder?.bytes, 500)
        XCTAssertEqual(folder?.isDirectory, true)

        // Both are on the ring at once, and only one of them is a sum: the name
        // alone can no longer tell them apart, and no longer has to.
        XCTAssertEqual(ring.filter { $0.name == "smaller items" }.count, 2)
        XCTAssertEqual(ring.filter(\.isAggregate).count, 1)
    }

    func testAnOrdinaryTreeHasNoAggregateAtAll() {
        let tree = node("root", 100, [node("a", 60), node("b", 40)])
        XCTAssertTrue(SunburstLayout.segments(for: tree, rings: 3).allSatisfy { !$0.isAggregate })
    }
}
