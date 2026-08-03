import XCTest
@testable import SoquelCore

final class VerifiedCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-verify-\(UUID().uuidString)", isDirectory: true)
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

    func testAMatchingCopyPasses() throws {
        let a = try write("a.txt", "payload")
        let b = try write("b.txt", "payload")
        XCTAssertEqual(VerifiedCopy.verify(source: a, destination: b).outcome, .passed)
    }

    /// The whole point: same size, different bytes, and nothing else would
    /// notice.
    func testACorruptedCopyFails() throws {
        let a = try write("a.txt", "payload")
        let b = try write("b.txt", "paylXad")
        XCTAssertEqual(VerifiedCopy.verify(source: a, destination: b).outcome, .failed)
    }

    /// A destination that is not there reports unreadable, not passed and not
    /// failed — nothing was compared, so nothing is claimed.
    func testAMissingDestinationIsUnreadableRatherThanFailed() throws {
        let a = try write("a.txt", "payload")
        let entry = VerifiedCopy.verify(source: a, destination: root.appendingPathComponent("gone.txt"))
        XCTAssertEqual(entry.outcome, .unreadable)
    }

    func testAFolderPassesWhenEveryFileUnderItMatches() throws {
        try write("one/x.txt", "hello")
        try write("one/deep/y.txt", "world")
        try write("two/x.txt", "hello")
        try write("two/deep/y.txt", "world")

        let entry = VerifiedCopy.verify(
            source: root.appendingPathComponent("one"),
            destination: root.appendingPathComponent("two")
        )
        XCTAssertEqual(entry.outcome, .passed)
    }

    /// A copy that dropped a file is a failure even though every file it did
    /// copy matches.
    func testAFolderMissingAFileFails() throws {
        try write("one/x.txt", "hello")
        try write("one/y.txt", "world")
        try write("two/x.txt", "hello")

        let entry = VerifiedCopy.verify(
            source: root.appendingPathComponent("one"),
            destination: root.appendingPathComponent("two")
        )
        XCTAssertEqual(entry.outcome, .failed)
    }

    func testTheManifestCountsAndReportsFailures() throws {
        let a = try write("a.txt", "same")
        let b = try write("b.txt", "same")
        let c = try write("c.txt", "one")
        let d = try write("d.txt", "two")

        let manifest = VerifiedCopy.verify(sources: [a, c], destinations: [b, d])
        XCTAssertEqual(manifest.passed, 1)
        XCTAssertEqual(manifest.failed.count, 1)
        XCTAssertFalse(manifest.isClean)
        XCTAssertTrue(manifest.summary.contains("did not match"), manifest.summary)
    }

    func testItIsOffByDefault() {
        XCTAssertFalse(VerifiedCopy.isEnabled, "hashing both ends reads every byte twice")
    }
}
