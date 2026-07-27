import XCTest
@testable import SoquelCore

/// Finder's Replace on a same-named folder unlinks the whole destination tree,
/// so anything in it that was not in the incoming folder is gone — no Trash
/// copy, nothing to undo. These tests pin down that Soquel does not.
final class FolderMergeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func file(_ path: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    private func run(
        _ sources: [URL], to destination: URL, move: Bool = false,
        resolve: @escaping (URL, URL) -> ConflictResolution
    ) -> OperationResult {
        let done = expectation(description: "transfer")
        var out = OperationResult()
        OperationEngine.shared.transfer(sources, to: destination, move: move,
                                        resolveConflict: resolve,
                                        completion: { out = $0; done.fulfill() })
        wait(for: [done], timeout: 15)
        return out
    }

    /// The headline case: merging keeps files that exist only on the
    /// destination side. Replace would have destroyed them.
    func testMergeKeepsFilesThatOnlyExistInTheDestination() throws {
        try file("incoming/project/new.txt", "new")
        try file("incoming/project/shared.txt", "incoming version")
        try file("dest/project/precious.txt", "must survive")
        try file("dest/project/shared.txt", "existing version")

        let result = run([dir.appendingPathComponent("incoming/project")],
                         to: dir.appendingPathComponent("dest")) { _, _ in
            ConflictResolution(choice: .merge, applyToAll: false, skipIdentical: false)
        }

        XCTAssertEqual(read("dest/project/precious.txt"), "must survive",
                       "a file only in the destination must survive a merge")
        XCTAssertEqual(read("dest/project/new.txt"), "new", "new files arrive")
        XCTAssertEqual(result.mergedDestinations.count, 1)
    }

    /// Nested folders merge all the way down rather than only at the top level.
    func testMergeRecursesIntoSubfolders() throws {
        try file("incoming/app/src/added.swift", "added")
        try file("dest/app/src/kept.swift", "kept")
        try file("dest/app/README.md", "readme")

        // Merge the folder; nested same-named folders recurse without asking,
        // so only colliding files would ever prompt — and here none do.
        var prompts = 0
        _ = run([dir.appendingPathComponent("incoming/app")],
                to: dir.appendingPathComponent("dest")) { _, _ in
            prompts += 1
            return ConflictResolution(choice: .merge)
        }
        XCTAssertEqual(prompts, 1, "only the top folder collides; src merges without a second prompt")

        XCTAssertEqual(read("dest/app/src/kept.swift"), "kept")
        XCTAssertEqual(read("dest/app/src/added.swift"), "added")
        XCTAssertEqual(read("dest/app/README.md"), "readme")
    }

    /// Inside a merge, each colliding file is still resolved individually.
    func testCollidingFilesInsideAMergeAreResolved() throws {
        try file("incoming/box/same.txt", "incoming")
        try file("dest/box/same.txt", "existing")

        _ = run([dir.appendingPathComponent("incoming/box")],
                to: dir.appendingPathComponent("dest")) { source, _ in
            // The top-level folder merges; the file inside is replaced.
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            return ConflictResolution(choice: isDirectory.boolValue ? .merge : .replace)
        }

        XCTAssertEqual(read("dest/box/same.txt"), "incoming")
    }

    /// Apply-to-all means the prompt is shown once, not once per file.
    func testApplyToAllAsksOnlyOnce() throws {
        for i in 1...5 { try file("incoming/bulk/f\(i).txt", "incoming \(i)") }
        for i in 1...5 { try file("dest/bulk/f\(i).txt", "existing \(i)") }

        var prompts = 0
        _ = run([dir.appendingPathComponent("incoming/bulk")],
                to: dir.appendingPathComponent("dest")) { source, _ in
            prompts += 1
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return ConflictResolution(choice: .merge) }
            return ConflictResolution(choice: .skip, applyToAll: true)
        }

        XCTAssertEqual(prompts, 2, "one prompt for the folder, one for the first file, then no more")
        XCTAssertEqual(read("dest/bulk/f5.txt"), "existing 5", "the standing Skip applied to every file")
    }

    /// Skip-identical leaves matching files alone without a prompt each time.
    func testSkipIdenticalLeavesMatchingFilesAlone() throws {
        let a = try file("incoming/pair/same.txt", "identical")
        let b = try file("dest/pair/same.txt", "identical")
        // Same size and modification date is what "identical" means here.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        XCTAssertTrue(looksIdentical(a, b))

        _ = run([dir.appendingPathComponent("incoming/pair")],
                to: dir.appendingPathComponent("dest")) { source, _ in
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return ConflictResolution(choice: .merge) }
            return ConflictResolution(choice: .replace, applyToAll: true, skipIdentical: true)
        }

        XCTAssertEqual(read("dest/pair/same.txt"), "identical")
    }

    func testLooksIdenticalRejectsDifferentSizes() throws {
        let a = try file("a.txt", "short")
        let b = try file("b.txt", "a much longer body")
        XCTAssertFalse(looksIdentical(a, b))
    }

    /// A move that merges should leave the source folder gone once emptied, but
    /// must never recursively delete a source that still holds skipped files.
    func testMergingMoveKeepsASourceThatStillHasFiles() throws {
        try file("incoming/keep/skipped.txt", "incoming")
        try file("dest/keep/skipped.txt", "existing")

        _ = run([dir.appendingPathComponent("incoming/keep")],
                to: dir.appendingPathComponent("dest"), move: true) { source, _ in
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return ConflictResolution(choice: .merge) }
            return ConflictResolution(choice: .skip)
        }

        XCTAssertEqual(read("incoming/keep/skipped.txt"), "incoming",
                       "a skipped file must not be deleted from the source")
        XCTAssertEqual(read("dest/keep/skipped.txt"), "existing")
    }

    /// A merge is not undoable — there is no record of which files were already
    /// there, so trashing the merged folder would take the user's own files.
    func testMergeIsNotPushedToUndo() throws {
        try file("incoming/u/new.txt", "new")
        try file("dest/u/old.txt", "old")

        let before = UndoStack.shared.canUndo
        let result = run([dir.appendingPathComponent("incoming/u")],
                         to: dir.appendingPathComponent("dest")) { _, _ in
            ConflictResolution(choice: .merge)
        }
        UndoStack.shared.pushCopy(result: result)
        XCTAssertEqual(UndoStack.shared.canUndo, before, "a merge must not become an undo entry")
    }

    /// Cancel inside a merge stops the whole operation.
    func testCancelInsideAMergeStops() throws {
        try file("incoming/c/one.txt", "incoming one")
        try file("incoming/c/two.txt", "incoming two")
        try file("dest/c/one.txt", "existing one")
        try file("dest/c/two.txt", "existing two")

        _ = run([dir.appendingPathComponent("incoming/c")],
                to: dir.appendingPathComponent("dest")) { source, _ in
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return ConflictResolution(choice: .merge) }
            return ConflictResolution(choice: .cancel)
        }

        XCTAssertEqual(read("dest/c/one.txt"), "existing one")
        XCTAssertEqual(read("dest/c/two.txt"), "existing two")
    }
}

final class FolderSizeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWalkAddsUpNestedFiles() throws {
        let deep = dir.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try String(repeating: "x", count: 5000).write(to: deep.appendingPathComponent("big.txt"),
                                                      atomically: true, encoding: .utf8)
        try "small".write(to: dir.appendingPathComponent("a/small.txt"), atomically: true, encoding: .utf8)

        let measured = FolderSizeCalculator.walk(dir.appendingPathComponent("a"))
        XCTAssertEqual(measured.fileCount, 2)
        XCTAssertGreaterThanOrEqual(measured.bytes, 5000, "allocated size covers the payload")
    }

    /// Finder counts each hard link as another copy; this counts the inode once.
    func testHardLinksAreCountedOnce() throws {
        let folder = dir.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.bin")
        try Data(repeating: 7, count: 20_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: folder.appendingPathComponent("hardlink.bin"))

        let measured = FolderSizeCalculator.walk(folder)
        XCTAssertEqual(measured.fileCount, 1, "two names, one file's worth of disk")
        XCTAssertLessThan(measured.bytes, 40_000, "the linked bytes must not be double-counted")
    }

    /// A symlink loop would never terminate if links were followed.
    func testSymlinkLoopTerminates() throws {
        let folder = dir.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "content".write(to: folder.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("self"),
                                                   withDestinationURL: folder)

        let measured = FolderSizeCalculator.walk(folder)
        XCTAssertEqual(measured.fileCount, 1)
    }

    func testEmptyFolderMeasuresZero() throws {
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let measured = FolderSizeCalculator.walk(empty)
        XCTAssertEqual(measured.bytes, 0)
        XCTAssertEqual(measured.fileCount, 0)
    }
}

final class FileTemplateTests: XCTestCase {
    func testEveryTemplateHasADistinctIdentifierAndExtension() {
        let ids = FileTemplate.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for template in FileTemplate.all {
            XCTAssertFalse(template.defaultName.isEmpty)
            XCTAssertTrue(template.defaultName.contains("."), "\(template.title) needs an extension")
        }
    }

    func testShellScriptIsCreatedExecutable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-tpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let created = try OperationEngine.shared.createFile(
            named: "run.sh", in: dir, contents: "#!/usr/bin/env bash\n"
        )
        let mode = (try FileManager.default.attributesOfItem(atPath: created.path)[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(mode.map { $0 & 0o111 } != 0, true, "a shell script you cannot run is not useful")
    }
}

extension FolderSizeTests {
    /// A folder holding an app bundle occupies the bundle's bytes. Skipping
    /// package descendants reported it as zero.
    func testBundleContentsCountTowardTheFolderSize() throws {
        let bundle = dir.appendingPathComponent("Thing.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 30_000).write(to: bundle.appendingPathComponent("Thing"))

        let measured = FolderSizeCalculator.walk(dir)
        XCTAssertEqual(measured.fileCount, 1)
        XCTAssertGreaterThanOrEqual(measured.bytes, 30_000, "a bundle is not zero bytes")
    }
}
