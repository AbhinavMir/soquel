import XCTest
@testable import SoquelCore

final class FolderPeekTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-peek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func make(_ names: [String], directories: Bool = false) throws {
        for name in names {
            let url = root.appendingPathComponent(name)
            if directories {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
        }
    }

    func testFoldersComeBeforeFiles() throws {
        try make(["b.txt", "a.txt"])
        try make(["zdir"], directories: true)

        let contents = FolderPeek.read(root, showHidden: false)
        XCTAssertEqual(contents.items.map(\.name), ["zdir", "a.txt", "b.txt"])
        XCTAssertEqual(contents.folders, 1)
        XCTAssertEqual(contents.files, 2)
    }

    func testHiddenFilesAreCountedButNotShownWhenOff() throws {
        try make(["visible.txt", ".hidden"])

        let off = FolderPeek.read(root, showHidden: false)
        XCTAssertEqual(off.items.count, 1)
        XCTAssertEqual(off.hidden, 1)

        let on = FolderPeek.read(root, showHidden: true)
        XCTAssertEqual(on.items.count, 2)
        XCTAssertEqual(on.hidden, 0)
    }

    func testAnEmptyFolderSaysSo() {
        XCTAssertEqual(FolderPeek.read(root, showHidden: false).summary, "Empty")
    }

    func testTheGridStopsAtTheTileLimitAndReportsTheRest() throws {
        try make((1...30).map { "f\($0).txt" })

        let contents = FolderPeek.read(root, showHidden: false)
        XCTAssertEqual(contents.items.count, 30)
        XCTAssertEqual(contents.shown.count, FolderPeek.tileLimit)
        XCTAssertEqual(contents.overflow, 30 - FolderPeek.tileLimit)
    }
}
