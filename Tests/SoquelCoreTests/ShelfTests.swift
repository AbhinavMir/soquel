import XCTest
@testable import SoquelCore

final class ShelfTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Shelf.clear()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Shelf.clear()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testStartsEmpty() {
        XCTAssertTrue(Shelf.isEmpty)
        XCTAssertEqual(Shelf.count, 0)
        XCTAssertEqual(Shelf.summary, "The shelf is empty")
    }

    func testAddingKeepsOrder() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        Shelf.add([first, second])
        XCTAssertEqual(Shelf.urls.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    /// Adding the same file twice must not double it — the shelf is a set that
    /// remembers its order, not a list.
    func testAddingTheSameFileTwiceAddsItOnce() throws {
        let url = try file("a.txt")
        XCTAssertEqual(Shelf.add([url]), 1)
        XCTAssertEqual(Shelf.add([url]), 0)
        XCTAssertEqual(Shelf.count, 1)
    }

    func testAddReportsHowManyWereNew() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        Shelf.add([first])
        XCTAssertEqual(Shelf.add([first, second]), 1)
    }

    func testFilesFromDifferentFoldersCoexist() throws {
        let other = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let outer = try file("same.txt")
        let inner = other.appendingPathComponent("same.txt")
        try Data("y".utf8).write(to: inner)

        Shelf.add([outer, inner])
        XCTAssertEqual(Shelf.count, 2)
    }

    func testRemovingOne() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        Shelf.add([first, second])
        Shelf.remove(first)
        XCTAssertEqual(Shelf.urls.map(\.lastPathComponent), ["b.txt"])
    }

    func testClearing() throws {
        Shelf.add([try file("a.txt")])
        Shelf.clear()
        XCTAssertTrue(Shelf.isEmpty)
    }

    func testContains() throws {
        let url = try file("a.txt")
        XCTAssertFalse(Shelf.contains(url))
        Shelf.add([url])
        XCTAssertTrue(Shelf.contains(url))
    }

    /// A shelf that offers to copy a file deleted an hour ago is worse than one
    /// that quietly shortens.
    func testDeletedFilesDropOffOnRead() throws {
        let kept = try file("kept.txt")
        let doomed = try file("doomed.txt")
        Shelf.add([kept, doomed])
        try FileManager.default.removeItem(at: doomed)
        XCTAssertEqual(Shelf.urls.map(\.lastPathComponent), ["kept.txt"])
        XCTAssertEqual(Shelf.count, 1)
    }

    func testSurvivesAcrossReadsBecauseItIsInSettings() throws {
        let url = try file("a.txt")
        Shelf.add([url])
        // Same store, re-read from the settings dictionary rather than a cache.
        XCTAssertEqual(Settings.stringArray(forKey: "shelfPaths"), [url.standardizedFileURL.path])
    }

    func testSummaryCounts() throws {
        Shelf.add([try file("a.txt")])
        XCTAssertEqual(Shelf.summary, "1 file on the shelf")
        Shelf.add([try file("b.txt")])
        XCTAssertEqual(Shelf.summary, "2 files on the shelf")
    }

    func testAddingNothingChangesNothing() {
        XCTAssertEqual(Shelf.add([]), 0)
        XCTAssertTrue(Shelf.isEmpty)
    }

    func testChangeIsAnnounced() throws {
        let url = try file("a.txt")
        expectation(forNotification: .soquelShelfChanged, object: nil)
        Shelf.add([url])
        waitForExpectations(timeout: 2)
    }
}
