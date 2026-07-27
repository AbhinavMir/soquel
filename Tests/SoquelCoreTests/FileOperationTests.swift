import XCTest
@testable import SoquelCore

final class FileOperationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testUniqueURLAppendsCounterBeforeExtension() throws {
        _ = try write("report.txt")
        let candidate = dir.appendingPathComponent("report.txt")
        let unique = OperationEngine.uniqueURL(for: candidate, fileManager: .default)
        XCTAssertEqual(unique.lastPathComponent, "report 2.txt")

        _ = try write("report 2.txt")
        XCTAssertEqual(
            OperationEngine.uniqueURL(for: candidate, fileManager: .default).lastPathComponent,
            "report 3.txt"
        )
    }

    func testUniqueURLLeavesFreeNamesAlone() {
        let free = dir.appendingPathComponent("nothing-here.txt")
        XCTAssertEqual(OperationEngine.uniqueURL(for: free, fileManager: .default), free)
    }

    func testRenameRejectsExistingName() throws {
        let a = try write("a.txt")
        _ = try write("b.txt")
        XCTAssertThrowsError(try OperationEngine.shared.rename(a, to: "b.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "source must survive a failed rename")
    }

    /// On a case-insensitive volume the destination "exists" because it is the
    /// same file; a case-only rename must still go through.
    func testCaseOnlyRename() throws {
        let a = try write("readme.md")
        let renamed = try OperationEngine.shared.rename(a, to: "README.md")
        XCTAssertEqual(renamed.lastPathComponent, "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["README.md"])
    }

    func testDuplicateCreatesCopySuffix() throws {
        let a = try write("photo.jpg")
        let created = try OperationEngine.shared.duplicate([a])
        XCTAssertEqual(created.map(\.lastPathComponent), ["photo copy.jpg"])

        let again = try OperationEngine.shared.duplicate([a])
        XCTAssertEqual(again.map(\.lastPathComponent), ["photo copy 2.jpg"])
    }

    func testDuplicateOfExtensionlessFile() throws {
        let a = try write("Makefile")
        let created = try OperationEngine.shared.duplicate([a])
        XCTAssertEqual(created.map(\.lastPathComponent), ["Makefile copy"])
    }

    func testCreateFolderRejectsDuplicate() throws {
        _ = try OperationEngine.shared.createFolder(named: "docs", in: dir)
        XCTAssertThrowsError(try OperationEngine.shared.createFolder(named: "docs", in: dir))
    }

    func testFileNameValidation() {
        XCTAssertNil(validateFileName("normal.txt"))
        XCTAssertNotNil(validateFileName(""))
        XCTAssertNotNil(validateFileName("   "))
        XCTAssertNotNil(validateFileName("a/b"))
        XCTAssertNotNil(validateFileName("a:b"))
        XCTAssertNotNil(validateFileName(".."))
        XCTAssertNotNil(validateFileName("."))
    }

    func testCopyKeepBothLeavesOriginalIntact() throws {
        let source = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "incoming".write(to: source.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "existing".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let done = expectation(description: "copy finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [source.appendingPathComponent("note.txt")],
            to: dir,
            move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .keepBoth) },
            completion: { result = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result?.failures.count, 0)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("note 2.txt"), encoding: .utf8), "incoming")
    }

    func testSkipLeavesDestinationUntouched() throws {
        let source = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "incoming".write(to: source.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "existing".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let done = expectation(description: "copy finished")
        OperationEngine.shared.transfer(
            [source.appendingPathComponent("note.txt")],
            to: dir,
            move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .skip) },
            completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8), "existing")
    }

    /// Dropping a file into the folder it already lives in must not delete it.
    func testMoveOntoItselfIsANoOp() throws {
        let file = try write("stay.txt", "keep me")
        let done = expectation(description: "move finished")
        OperationEngine.shared.transfer(
            [file],
            to: dir,
            move: true,
            resolveConflict: { _, _ in XCTFail("must not prompt for a self-move"); return ConflictResolution(choice: .skip) },
            completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
    }
}

final class SortAndFilterTests: XCTestCase {
    private func item(_ name: String, dir: Bool = false, size: Int64 = 0, kind: String = "Doc") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: dir,
                 isPackage: false, isSymlink: false, isHidden: false,
                 size: dir ? -1 : size, modified: .distantPast, created: .distantPast, kind: kind)
    }

    func testFoldersFirstBeatsSortKey() {
        let items = [item("zeta", dir: true), item("alpha", size: 10)]
        let sorted = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .name, ascending: true)]), foldersFirst: true)
        XCTAssertEqual(sorted.map(\.name), ["zeta", "alpha"])
    }

    func testFoldersFirstDisabled() {
        let items = [item("zeta", dir: true), item("alpha", size: 10)]
        let sorted = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .name, ascending: true)]), foldersFirst: false)
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta"])
    }

    func testNaturalNameOrdering() {
        let items = [item("file10"), item("file2"), item("File1")]
        let sorted = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .name, ascending: true)]), foldersFirst: false)
        XCTAssertEqual(sorted.map(\.name), ["File1", "file2", "file10"])
    }

    /// Largest first, but two files of the same size stay in name order rather
    /// than flipping with the column direction.
    func testSizeDescendingKeepsNameTiebreakAscending() {
        let items = [item("b", size: 5), item("a", size: 5), item("c", size: 99)]
        let sorted = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .size, ascending: false)]), foldersFirst: false)
        XCTAssertEqual(sorted.map(\.name), ["c", "a", "b"])
    }

    func testSortByKindGroupsLikeFilesAndBreaksTiesByName() {
        let items = [
            item("notes.txt", kind: "Plain Text Document"),
            item("b.png", kind: "PNG image"),
            item("archive.zip", kind: "ZIP archive"),
            item("a.png", kind: "PNG image"),
        ]
        // Kinds order as "Plain Text Document" < "PNG image" < "ZIP archive".
        let ascending = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .kind, ascending: true)]), foldersFirst: false)
        XCTAssertEqual(ascending.map(\.name), ["notes.txt", "a.png", "b.png", "archive.zip"])

        let descending = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .kind, ascending: false)]), foldersFirst: false)
        XCTAssertEqual(descending.map(\.name), ["archive.zip", "a.png", "b.png", "notes.txt"],
                       "reversing the kind order must keep the name tiebreak ascending within a kind")
    }

    func testSortByKindKeepsFoldersFirstWhenEnabled() {
        let items = [
            item("zzz.txt", kind: "Plain Text Document"),
            item("assets", dir: true, kind: "Folder"),
        ]
        let sorted = sortItems(items, order: SortOrder(descriptors: [SortDescriptorSpec(key: .kind, ascending: true)]), foldersFirst: true)
        XCTAssertEqual(sorted.map(\.name), ["assets", "zzz.txt"])
    }

    func testFuzzyScoreMatchesSubsequenceOnly() {
        XCTAssertNotNil(fuzzyScore("cp", "Copy Path"))
        XCTAssertNotNil(fuzzyScore("split right", "Split Pane Right"))
        XCTAssertNil(fuzzyScore("zzz", "Copy Path"))
        XCTAssertEqual(fuzzyScore("", "anything"), 0)
    }

    func testFuzzyScoreRanksContiguousMatchesBetter() {
        let tight = fuzzyScore("copy", "Copy Path")!
        let loose = fuzzyScore("copy", "Compare Opposite Pane Yield")!
        XCTAssertLessThan(tight, loose)
    }
}

/// The stage-then-swap dance claims a failure leaves the existing item
/// untouched. It did not: the destination was deleted first, so a move that
/// failed in the gap left nothing at all.
final class SwapIntoPlaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testTheStagedItemTakesTheDestinationsPlace() throws {
        let destination = root.appendingPathComponent("a.txt")
        let staged = root.appendingPathComponent(".soquel-incoming-a.txt")
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        try "new".write(to: staged, atomically: true, encoding: .utf8)

        try OperationEngine.swapIntoPlace(staged: staged, destination: destination,
                                         fileManager: FileManager())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    /// The staged item is missing, so the move cannot succeed. The existing
    /// file has to still be there afterwards.
    func testAFailedSwapLeavesTheDestinationWhereItWas() throws {
        let destination = root.appendingPathComponent("a.txt")
        try "keep me".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OperationEngine.swapIntoPlace(
            staged: root.appendingPathComponent("never-existed"),
            destination: destination, fileManager: FileManager()))

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep me",
                       "the destination was deleted before the swap was known to work")
    }

    /// Same guarantee when the thing being replaced is a whole folder.
    func testAFailedSwapPutsAFolderBack() throws {
        let destination = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "important".write(to: destination.appendingPathComponent("keep.txt"),
                              atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OperationEngine.swapIntoPlace(
            staged: root.appendingPathComponent("never-existed"),
            destination: destination, fileManager: FileManager()))

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8),
            "important", "the folder was destroyed by a swap that never happened")
    }

    /// Nothing at the destination is the ordinary case, not an error.
    func testSwappingOntoNothingJustPutsTheItemThere() throws {
        let destination = root.appendingPathComponent("fresh.txt")
        let staged = root.appendingPathComponent(".soquel-incoming-fresh.txt")
        try "hello".write(to: staged, atomically: true, encoding: .utf8)

        try OperationEngine.swapIntoPlace(staged: staged, destination: destination,
                                         fileManager: FileManager())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
    }
}
