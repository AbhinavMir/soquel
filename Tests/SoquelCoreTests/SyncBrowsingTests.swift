import XCTest
@testable import SoquelCore

final class SyncBrowsingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testASingleFolderIsShownInTheOtherPane() {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        XCTAssertEqual(MainWindowController.syncTarget(for: [folder]), folder)
    }

    /// A file has no contents to show, so the other pane stays put rather than
    /// being emptied or sent to the file's parent.
    func testAFileShowsNothing() {
        XCTAssertNil(MainWindowController.syncTarget(for: [root.appendingPathComponent("file.txt")]))
    }

    func testAMultipleOrEmptySelectionShowsNothing() {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        XCTAssertNil(MainWindowController.syncTarget(for: []))
        XCTAssertNil(MainWindowController.syncTarget(for: [folder, root]))
    }

    func testAFolderThatHasGoneShowsNothing() {
        XCTAssertNil(MainWindowController.syncTarget(for: [root.appendingPathComponent("missing")]))
    }

    func testItIsOffByDefault() {
        XCTAssertFalse(Prefs.syncBrowsing, "sending the other pane somewhere unasked is a surprise")
    }
}
