import XCTest
@testable import SoquelCore

final class SymlinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A real symlink, which is what the shell follows. An alias is a data fork
    /// the shell cannot read.
    func testItMakesARealSymlink() throws {
        let target = root.appendingPathComponent("target.txt")
        try Data("payload".utf8).write(to: target)

        let link = try OperationEngine.shared.createSymlink(to: target, in: root, named: "link")
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "payload")
    }

    /// Relative when both ends share a parent, so renaming the folder around
    /// them does not break the link.
    func testALinkBesideItsTargetIsRelative() throws {
        let target = root.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)

        try OperationEngine.shared.createSymlink(to: target, in: root, named: "link")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("link").path
        )
        XCTAssertEqual(destination, "target.txt")
    }

    func testALinkElsewhereIsAbsolute() throws {
        let elsewhere = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)

        let path = OperationEngine.linkDestination(to: target, from: elsewhere)
        XCTAssertTrue(path.hasPrefix("/"), path)
    }

    /// Naming the link after the file would collide with the file itself.
    func testTheLinkIsNamedApartFromItsTarget() throws {
        let target = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: target)

        let first = FileListViewController.symlinkName(for: target, in: root)
        XCTAssertEqual(first, "notes.txt symlink")

        try OperationEngine.shared.createSymlink(to: target, in: root, named: first)
        XCTAssertEqual(FileListViewController.symlinkName(for: target, in: root), "notes.txt symlink 2")
    }

    func testAnExistingNameIsRefusedRatherThanOverwritten() throws {
        let target = root.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)
        try Data("important".utf8).write(to: root.appendingPathComponent("taken"))

        XCTAssertThrowsError(try OperationEngine.shared.createSymlink(to: target, in: root, named: "taken"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("taken"), encoding: .utf8), "important"
        )
    }

    func testTheStatusLineNamesWhatHappened() {
        let one = [URL(fileURLWithPath: "/a")]
        XCTAssertEqual(FileListViewController.symlinkStatus(created: one, failed: []), "Made 1 symlink")
        XCTAssertEqual(FileListViewController.symlinkStatus(created: [], failed: ["x"]), "Could not link x")
        XCTAssertEqual(
            FileListViewController.symlinkStatus(created: one, failed: ["x"]),
            "Made 1 symlinks, 1 failed"
        )
    }
}
