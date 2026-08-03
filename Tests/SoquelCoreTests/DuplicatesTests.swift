import XCTest
@testable import SoquelCore

final class DuplicatesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-dupes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func write(_ path: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(body.utf8).write(to: url)
        return url
    }

    func testIdenticalFilesAreGrouped() throws {
        try write("a.txt", "same")
        try write("b.txt", "same")
        try write("c.txt", "different")

        let report = Duplicates.scan(roots: [root], includeHidden: false)
        XCTAssertEqual(report.fileGroups.count, 1)
        XCTAssertEqual(report.fileGroups[0].urls.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    /// Same size, different bytes. Grouping by size alone would call these a
    /// pair and offer to delete one.
    func testSameSizeDifferentContentIsNotADuplicate() throws {
        try write("a.txt", "aaaa")
        try write("b.txt", "bbbb")
        XCTAssertTrue(Duplicates.scan(roots: [root], includeHidden: false).groups.isEmpty)
    }

    /// Every empty file matches every other one. True, and useless.
    func testEmptyFilesAreIgnored() throws {
        try write("a.txt", "")
        try write("b.txt", "")
        XCTAssertTrue(Duplicates.scan(roots: [root], includeHidden: false).groups.isEmpty)
    }

    func testFoldersWithIdenticalContentsAreReportedAsOneGroup() throws {
        try write("one/x.txt", "hello")
        try write("one/y.txt", "world")
        try write("two/x.txt", "hello")
        try write("two/y.txt", "world")

        let report = Duplicates.scan(roots: [root], includeHidden: false)
        XCTAssertEqual(report.folderGroups.count, 1)
        XCTAssertEqual(report.folderGroups[0].urls.map(\.lastPathComponent), ["one", "two"])
    }

    /// A folder missing one file is not the same folder.
    func testFoldersDifferingByOneFileAreNotDuplicates() throws {
        try write("one/x.txt", "hello")
        try write("one/y.txt", "world")
        try write("two/x.txt", "hello")

        XCTAssertTrue(Duplicates.scan(roots: [root], includeHidden: false).folderGroups.isEmpty)
    }

    /// The shortest path wins, so the working copy outlives the one buried in
    /// an old backup folder.
    func testTheShallowestCopyIsSuggestedAsTheKeeper() {
        let group = Duplicates.Group(
            hash: "h", size: 10,
            urls: [
                root.appendingPathComponent("old/backup 2/report.pdf"),
                root.appendingPathComponent("report.pdf"),
            ]
        )
        XCTAssertEqual(Duplicates.suggestedKeep(group)?.lastPathComponent, "report.pdf")
        XCTAssertEqual(Duplicates.trashable(group, keeping: Duplicates.suggestedKeep(group)).count, 1)
    }

    /// Reclaimable is what the extra copies cost, not the total.
    func testReclaimableExcludesTheCopyBeingKept() {
        let group = Duplicates.Group(hash: "h", size: 100, urls: [root, root, root])
        XCTAssertEqual(group.reclaimable, 200)
    }

    /// Nothing to keep means nothing to trash — the guard against deleting
    /// every copy in a group.
    func testTrashableIsEmptyWithoutAKeeper() {
        let group = Duplicates.Group(hash: "h", size: 10, urls: [root])
        XCTAssertTrue(Duplicates.trashable(group, keeping: nil).isEmpty)
    }
}
