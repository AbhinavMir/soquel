import XCTest
@testable import SoquelCore

/// One test per defect found in review. Each documents the exact scenario that
/// used to misbehave.
final class RegressionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-regress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Data loss

    /// Copy then paste into the same folder used to hit the conflict prompt;
    /// choosing Replace deleted the destination first — which was the source —
    /// and the file was gone for good.
    func testPasteIntoOwnFolderWithReplaceKeepsTheFile() throws {
        let file = dir.appendingPathComponent("only-copy.txt")
        try "irreplaceable".write(to: file, atomically: true, encoding: .utf8)

        let done = expectation(description: "transfer finished")
        OperationEngine.shared.transfer(
            [file], to: dir, move: false,
            resolveConflict: { _, _ in
                XCTFail("a file landing on its own path is not a conflict")
                return ConflictResolution(choice: .replace)
            },
            completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "irreplaceable")
    }

    /// /tmp is a symlink to /private/tmp. Comparing raw URLs made the same file
    /// look like two different ones, defeating the self-copy guard.
    func testSamePathSeesThroughSymlinkedParents() throws {
        let real = URL(fileURLWithPath: "/private/tmp/soquel-symlink-check.txt")
        try? FileManager.default.removeItem(at: real)
        try "x".write(to: real, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: real) }

        let viaSymlink = URL(fileURLWithPath: "/tmp/soquel-symlink-check.txt")
        XCTAssertTrue(samePath(real, viaSymlink))
        XCTAssertFalse(samePath(real, URL(fileURLWithPath: "/private/tmp/other.txt")))
    }

    /// Copying a folder into a folder inside itself walked the tree it was
    /// writing into and produced nested copies until the path limit.
    func testCopyingFolderIntoItsOwnSubtreeIsRejected() throws {
        let outer = dir.appendingPathComponent("project", isDirectory: true)
        let inner = outer.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        XCTAssertTrue(isDescendant(inner, of: outer))
        XCTAssertFalse(isDescendant(outer, of: inner))

        let done = expectation(description: "transfer finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [outer], to: inner, move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .replace) },
            completion: { result = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 10)

        XCTAssertEqual(result?.succeeded.count, 0)
        XCTAssertEqual(result?.failures.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: inner.appendingPathComponent("project").path),
            "nothing should have been written into the subtree"
        )
    }

    /// Replace removed the destination before the copy ran, so a copy that
    /// failed afterwards left the user with neither file. The incoming item is
    /// now staged first and swapped in only once it is safely on disk.
    func testFailedReplaceLeavesTheOriginalInPlace() throws {
        let source = dir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = source.appendingPathComponent("doc.txt")
        try "new".write(to: payload, atomically: true, encoding: .utf8)

        let destinationDir = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let existing = destinationDir.appendingPathComponent("doc.txt")
        try "original".write(to: existing, atomically: true, encoding: .utf8)

        // Deleting the source mid-flight makes the copy fail after the choice.
        let done = expectation(description: "transfer finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [payload], to: destinationDir, move: false,
            resolveConflict: { _, _ in
                try? FileManager.default.removeItem(at: payload)
                return ConflictResolution(choice: .replace)
            },
            completion: { result = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result?.failures.count, 1, "the copy must be reported as failed")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original",
                       "a failed Replace must not destroy the existing file")
    }

    /// Replace on a successful copy still has to end with the incoming content
    /// and no leftover staging file.
    func testSuccessfulReplaceSwapsContentAndLeavesNoStagingFile() throws {
        let source = dir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)

        let destinationDir = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try "original".write(to: destinationDir.appendingPathComponent("doc.txt"),
                             atomically: true, encoding: .utf8)

        let done = expectation(description: "transfer finished")
        OperationEngine.shared.transfer(
            [source.appendingPathComponent("doc.txt")], to: destinationDir, move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .replace) },
            completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(
            try String(contentsOf: destinationDir.appendingPathComponent("doc.txt"), encoding: .utf8),
            "new"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destinationDir.path)
        XCTAssertEqual(leftovers, ["doc.txt"], "staging file must not survive")
    }

    // MARK: - Undo

    /// A copy that replaced an existing file is not undoable: trashing the new
    /// file would not bring the replaced one back, leaving neither. Such
    /// destinations are kept out of the undo entry.
    func testUndoOfAReplacingCopyDoesNotDeleteTheSurvivingFile() throws {
        let source = dir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)

        let destinationDir = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try "original".write(to: destinationDir.appendingPathComponent("doc.txt"),
                             atomically: true, encoding: .utf8)

        let done = expectation(description: "copy finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [source.appendingPathComponent("doc.txt")], to: destinationDir, move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .replace) },
            completion: { result = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result?.replacedDestinations.count, 1)

        let before = UndoStack.shared.canUndo
        UndoStack.shared.pushCopy(result: result!)
        XCTAssertEqual(UndoStack.shared.canUndo, before,
                       "a replacing copy must not push an undo entry")
        XCTAssertEqual(
            try String(contentsOf: destinationDir.appendingPathComponent("doc.txt"), encoding: .utf8),
            "new"
        )
    }

    /// A non-replacing copy stays undoable.
    func testUndoOfAPlainCopyIsStillPushed() throws {
        let source = dir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("fresh.txt"), atomically: true, encoding: .utf8)

        let destinationDir = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let done = expectation(description: "copy finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [source.appendingPathComponent("fresh.txt")], to: destinationDir, move: false,
            resolveConflict: { _, _ in ConflictResolution(choice: .skip) },
            completion: { result = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertTrue(result!.replacedDestinations.isEmpty)
        UndoStack.shared.pushCopy(result: result!)
        XCTAssertTrue(UndoStack.shared.canUndo)
        XCTAssertEqual(UndoStack.shared.topLabel, "Copy")
    }

    /// Progress used to be a single closure, so opening a second window left the
    /// first window's status bar permanently blank.
    func testEveryActivityObserverIsNotified() {
        var first: [Int] = []
        var second: [Int] = []
        let a = OperationEngine.shared.addActivityObserver { count, _ in first.append(count) }
        let b = OperationEngine.shared.addActivityObserver { count, _ in second.append(count) }
        defer {
            OperationEngine.shared.removeActivityObserver(a)
            OperationEngine.shared.removeActivityObserver(b)
        }

        let done = expectation(description: "trash finished")
        OperationEngine.shared.trash([dir.appendingPathComponent("missing.txt")]) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertFalse(first.isEmpty, "first observer must still receive progress")
        XCTAssertEqual(first, second, "both windows must see the same progress")
    }

    func testUndoOfMovePutsFilesBack() throws {
        let from = dir.appendingPathComponent("from", isDirectory: true)
        let to = dir.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let file = from.appendingPathComponent("moved.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let moved = expectation(description: "move finished")
        var result: OperationResult?
        OperationEngine.shared.transfer(
            [file], to: to, move: true,
            resolveConflict: { _, _ in ConflictResolution(choice: .skip) },
            completion: { result = $0; moved.fulfill() }
        )
        wait(for: [moved], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("moved.txt").path))

        UndoStack.shared.pushMove(sources: result!.succeeded, destinations: result!.createdDestinations)
        XCTAssertTrue(UndoStack.shared.canUndo)

        let undone = expectation(description: "undo finished")
        UndoStack.shared.undo { label, error in
            XCTAssertEqual(label, "Move")
            XCTAssertNil(error)
            undone.fulfill()
        }
        wait(for: [undone], timeout: 5)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent("moved.txt").path))
    }
}
