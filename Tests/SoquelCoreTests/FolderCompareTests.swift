import XCTest
@testable import SoquelCore

final class FolderCompareTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-compare-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        for url in [left!, right!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ contents: String, to parent: URL, _ path: String,
                       modified: Date? = nil) throws -> URL {
        let url = parent.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func entry(_ entries: [FolderCompare.Entry], _ path: String) -> FolderCompare.Entry? {
        entries.first { $0.relativePath == path }
    }

    // MARK: - Comparing

    func testIdenticalTreesReportNoDifferences() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write("hello", to: left, "a.txt", modified: stamp)
        try write("hello", to: right, "a.txt", modified: stamp)

        let entries = FolderCompare.compare(left: left, right: right)
        XCTAssertEqual(entry(entries, "a.txt")?.status, .identical)
        XCTAssertEqual(FolderCompare.summarize(entries).differenceCount, 0)
    }

    func testFilesPresentOnOneSideOnly() throws {
        try write("x", to: left, "onlyleft.txt")
        try write("y", to: right, "onlyright.txt")

        let entries = FolderCompare.compare(left: left, right: right)
        XCTAssertEqual(entry(entries, "onlyleft.txt")?.status, .onlyLeft)
        XCTAssertEqual(entry(entries, "onlyright.txt")?.status, .onlyRight)

        let summary = FolderCompare.summarize(entries)
        XCTAssertEqual(summary.onlyLeft, 1)
        XCTAssertEqual(summary.onlyRight, 1)
    }

    func testDifferentSizeIsADifference() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write("short", to: left, "a.txt", modified: stamp)
        try write("much longer contents", to: right, "a.txt", modified: stamp)
        XCTAssertEqual(entry(FolderCompare.compare(left: left, right: right), "a.txt")?.status, .differs)
    }

    func testDifferentTimestampIsADifferenceInQuickMode() throws {
        try write("same", to: left, "a.txt", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try write("same", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1_700_009_999))
        XCTAssertEqual(entry(FolderCompare.compare(left: left, right: right), "a.txt")?.status, .differs)
    }

    /// The same bytes with different timestamps are the same file, and checksum
    /// mode is the setting that says so.
    func testChecksumModeIgnoresTimestamps() throws {
        try write("same", to: left, "a.txt", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try write("same", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1_700_009_999))
        let entries = FolderCompare.compare(left: left, right: right, precision: .checksum)
        XCTAssertEqual(entry(entries, "a.txt")?.status, .identical)
    }

    func testChecksumModeCatchesEqualSizedDifferentContents() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write("aaaa", to: left, "a.txt", modified: stamp)
        try write("bbbb", to: right, "a.txt", modified: stamp)
        let entries = FolderCompare.compare(left: left, right: right, precision: .checksum)
        XCTAssertEqual(entry(entries, "a.txt")?.status, .differs)
    }

    func testNestedPathsArePairedByRelativePath() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write("deep", to: left, "one/two/three.txt", modified: stamp)
        try write("deep", to: right, "one/two/three.txt", modified: stamp)
        let entries = FolderCompare.compare(left: left, right: right)
        XCTAssertEqual(entry(entries, "one/two/three.txt")?.status, .identical)
        XCTAssertEqual(entry(entries, "one")?.status, .identical)
    }

    func testAFolderAgainstAFileIsATypeConflict() throws {
        try FileManager.default.createDirectory(
            at: left.appendingPathComponent("thing"), withIntermediateDirectories: true
        )
        try write("not a folder", to: right, "thing")
        XCTAssertEqual(entry(FolderCompare.compare(left: left, right: right), "thing")?.status, .typeConflict)
    }

    func testHiddenFilesCanBeExcluded() throws {
        try write("secret", to: left, ".hidden")
        XCTAssertNotNil(entry(FolderCompare.compare(left: left, right: right), ".hidden"))
        let visible = FolderCompare.compare(left: left, right: right, includeHidden: false)
        XCTAssertNil(entry(visible, ".hidden"))
    }

    func testComparingEmptyFoldersYieldsNothing() {
        XCTAssertTrue(FolderCompare.compare(left: left, right: right).isEmpty)
    }

    // MARK: - Planning

    func testPlanCopiesOnlyWhatExistsOnTheSourceSide() throws {
        try write("x", to: left, "onlyleft.txt")
        try write("y", to: right, "onlyright.txt")
        let entries = FolderCompare.compare(left: left, right: right)

        let toRight = FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        XCTAssertEqual(toRight.map(\.relativePath), ["onlyleft.txt"])
        XCTAssertEqual(toRight.first?.destination, right.appendingPathComponent("onlyleft.txt"))
        XCTAssertEqual(toRight.first?.overwrites, false)

        let toLeft = FolderCompare.plan(entries, direction: .rightToLeft, left: left, right: right)
        XCTAssertEqual(toLeft.map(\.relativePath), ["onlyright.txt"])
    }

    func testPlanFlagsOverwrites() throws {
        try write("old", to: left, "a.txt")
        try write("new", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1))
        let entries = FolderCompare.compare(left: left, right: right)
            .filter { $0.status.isDifference }
        let plans = FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        XCTAssertEqual(plans.first?.overwrites, true)
    }

    func testPlanSkipsFolders() throws {
        try FileManager.default.createDirectory(
            at: left.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        let entries = FolderCompare.compare(left: left, right: right)
        XCTAssertTrue(FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right).isEmpty)
    }

    /// File on one side, folder on the other. Syncing the file across would
    /// delete the folder and everything in it, while the sheet counted the
    /// whole tree as one replaced file.
    func testPlanRefusesToPutAFileWhereAFolderIs() throws {
        try write("I am a file", to: left, "docs")
        try write("keep me", to: right, "docs/important.txt")

        let entries = FolderCompare.compare(left: left, right: right)
        XCTAssertEqual(entry(entries, "docs")?.status, .typeConflict)

        let plans = FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        XCTAssertTrue(plans.filter { $0.relativePath == "docs" }.isEmpty,
                      "a type conflict became a plan that deletes a tree")
    }

    /// Even handed a plan that says to do it, apply() must not.
    func testApplyRefusesToReplaceAFolderWithAFile() throws {
        let source = try write("I am a file", to: left, "docs")
        try write("keep me", to: right, "docs/important.txt")

        let plan = FolderCompare.Plan(
            source: source,
            destination: right.appendingPathComponent("docs"),
            relativePath: "docs",
            overwrites: true
        )
        XCTAssertThrowsError(try FolderCompare.apply([plan]))
        XCTAssertEqual(
            try String(contentsOf: right.appendingPathComponent("docs/important.txt"), encoding: .utf8),
            "keep me", "the folder's contents were destroyed")
    }

    // MARK: - Applying

    func testApplyCopiesNewFilesAndCreatesParents() throws {
        try write("payload", to: left, "one/two/new.txt")
        let entries = FolderCompare.compare(left: left, right: right)
        let plans = FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)

        XCTAssertEqual(try FolderCompare.apply(plans), 1)
        let copied = right.appendingPathComponent("one/two/new.txt")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "payload")
    }

    func testApplyReplacesAnExistingFile() throws {
        try write("left version", to: left, "a.txt")
        try write("right version", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1))
        let entries = FolderCompare.compare(left: left, right: right).filter { $0.status.isDifference }
        try FolderCompare.apply(
            FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        )
        XCTAssertEqual(
            try String(contentsOf: right.appendingPathComponent("a.txt"), encoding: .utf8),
            "left version"
        )
    }

    /// Replacing must never consume the source: the file being copied from has
    /// to still be there afterwards.
    func testApplyLeavesTheSourceInPlace() throws {
        try write("left version", to: left, "a.txt")
        try write("right version", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1))
        let entries = FolderCompare.compare(left: left, right: right).filter { $0.status.isDifference }
        try FolderCompare.apply(
            FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        )
        XCTAssertEqual(
            try String(contentsOf: left.appendingPathComponent("a.txt"), encoding: .utf8),
            "left version"
        )
    }

    func testSyncingMakesTheTwoSidesCompareEqual() throws {
        try write("one", to: left, "one.txt")
        try write("two", to: left, "nested/two.txt")
        try write("stale", to: right, "one.txt", modified: Date(timeIntervalSince1970: 1))

        let entries = FolderCompare.compare(left: left, right: right).filter { $0.status.isDifference }
        try FolderCompare.apply(
            FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        )

        let after = FolderCompare.compare(left: left, right: right, precision: .checksum)
        XCTAssertEqual(after.filter { $0.status.isDifference }.map(\.relativePath), [])
    }

    func testCancellationStopsTheWalk() throws {
        for index in 0..<50 { try write("x", to: left, "file\(index).txt") }
        let entries = FolderCompare.compare(left: left, right: right, isCancelled: { true })
        XCTAssertTrue(entries.isEmpty)
    }
}
