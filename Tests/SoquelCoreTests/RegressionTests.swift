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

    /// Clicking a pinned favourite navigated the pane, the pane reported its
    /// new folder, and the tree followed it by selecting its own node for that
    /// folder — taking the highlight straight off the favourite that had just
    /// been clicked. The tree still opens down to the folder; it no longer
    /// steals the selected row.
    func testRevealDoesNotTakeSelectionOffAClickedFavourite() {
        let item = SidebarItem(path: "/soquel-reveal/home/Work")
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: .pinned(item)))

        let volume = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: .volume(volume, "Backup")))
    }

    /// This used to assert the opposite. A pane moved from outside the sidebar
    /// — a double-click in the file list, Back, the path bar — arrives with no
    /// origin, and following it moved the highlight and scrolled the opened
    /// folder to the top of the sidebar. Nothing the user did was in the
    /// sidebar, so nothing in the sidebar should move.
    func testRevealNoLongerFollowsAPaneMovedFromOutsideTheSidebar() {
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: nil))

        // A click in the tree itself still moves it: that is the tree's own
        // selection being kept in step with the pane it just opened.
        let folder = URL(fileURLWithPath: "/soquel-reveal/home", isDirectory: true)
        XCTAssertTrue(SidebarViewController.revealMovesSelection(navigatedFrom: .treeFolder(folder)))
    }

    /// The hidden-files button drew an eye in both states, so it said "here is
    /// something about visibility" without ever saying which way it was set.
    func testTheHiddenFilesButtonDrawsBothStates() {
        guard let action = ToolbarCatalogue.action(id: "hidden") else {
            return XCTFail("no hidden action")
        }
        let wasShowing = Prefs.showHiddenFiles
        defer { Prefs.showHiddenFiles = wasShowing }

        Prefs.showHiddenFiles = true
        XCTAssertEqual(action.currentSymbol, "eye")
        XCTAssertEqual(action.currentTitle, "Hide Hidden Files")

        Prefs.showHiddenFiles = false
        XCTAssertEqual(action.currentSymbol, "eye.slash")
        XCTAssertEqual(action.currentTitle, "Show Hidden Files")
    }

    /// An action with no off-symbol keeps its one symbol and title whichever
    /// way it is set.
    func testAnActionWithoutAnOppositeSymbolIsUnchanged() {
        guard let action = ToolbarCatalogue.action(id: "newFolder") else {
            return XCTFail("no newFolder action")
        }
        XCTAssertEqual(action.currentSymbol, "folder.badge.plus")
        XCTAssertEqual(action.currentTitle, "New Folder")
    }

    /// A package is a directory macOS presents as one file. Looking inside is
    /// offered for any of them, not only .app — an .rtfd and an .xcodeproj are
    /// worth opening up too — and never for an ordinary folder or a plain file.
    func testOnlyPackagesOfferToBeLookedInside() {
        XCTAssertTrue(PackageContents.canInspect(stubItem(directory: true, package: true)))
        XCTAssertFalse(PackageContents.canInspect(stubItem(directory: true, package: false)))
        XCTAssertFalse(PackageContents.canInspect(stubItem(directory: false, package: false)))
        // A bundle flag on something that is not a directory is nonsense, and
        // must not open a browser over an empty listing.
        XCTAssertFalse(PackageContents.canInspect(stubItem(directory: false, package: true)))
    }

    /// Folders come before files and each group sorts by name, so a bundle
    /// opens the same way twice running.
    func testPackageRowsSortFoldersFirstThenByName() {
        let items = [
            stubItem(directory: false, package: false, name: "Info.plist"),
            stubItem(directory: true, package: false, name: "Resources"),
            stubItem(directory: false, package: false, name: "CodeResources"),
            stubItem(directory: true, package: false, name: "MacOS"),
        ]
        XCTAssertEqual(
            PackageContents.sorted(items).map(\.name),
            ["MacOS", "Resources", "CodeResources", "Info.plist"]
        )
    }

    /// The footer counts everything underneath, not the top level, and reports
    /// bytes rather than an item count alone.
    func testPackageSummaryWalksTheWholeBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-pkg-\(UUID().uuidString).app", isDirectory: true)
        let inner = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x41, count: 2048).write(to: inner.appendingPathComponent("binary"))
        try Data("plist".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))

        let summary = PackageContents.summarise(root)
        XCTAssertEqual(summary.files, 2)
        XCTAssertEqual(summary.folders, 2, "Contents and Contents/MacOS")
        XCTAssertGreaterThanOrEqual(summary.bytes, 2048)
        XCTAssertTrue(summary.text.contains("2 files"), summary.text)
    }

    /// A bundle that links the same framework twice is not twice the size, and
    /// a symlink out of the bundle must not drag the whole target in.
    func testPackageSummaryCountsAHardLinkOnceAndIgnoresSymlinks() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-pkg-\(UUID().uuidString).app", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let real = root.appendingPathComponent("real")
        try Data(repeating: 0x42, count: 4096).write(to: real)
        try fm.linkItem(at: real, to: root.appendingPathComponent("hardlink"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("symlink"), withDestinationURL: real)

        let summary = PackageContents.summarise(root)
        XCTAssertEqual(summary.files, 1, "the hard link is the same inode, the symlink is not followed")
    }

    private func stubItem(directory: Bool, package: Bool, name: String = "Thing") -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/soquel-stub/\(name)"),
            name: name,
            isDirectory: directory,
            isPackage: package,
            isSymlink: false,
            isHidden: false,
            size: directory ? -1 : 10,
            modified: .distantPast,
            created: .distantPast,
            kind: directory ? "Folder" : "Document"
        )
    }

    /// The tree used to list folders only, so a folder holding nothing but
    /// files looked empty. Files show now, capped so a Downloads folder cannot
    /// bury every folder under it.
    func testTreeShowsFilesUpToTheLimitThenOneMoreRow() {
        let parent = URL(fileURLWithPath: "/soquel-tree", isDirectory: true)
        let folders = (1...2).map { parent.appendingPathComponent("dir\($0)", isDirectory: true) }
        let files = (1...30).map { parent.appendingPathComponent("file\($0).txt") }

        let level = FolderTree.split(folders: folders, files: files)
        XCTAssertEqual(level.folders.count, 2)
        XCTAssertEqual(level.files.count, FolderTree.fileLimit)
        XCTAssertEqual(level.overflow.count, 30 - FolderTree.fileLimit)

        let nodes = SidebarViewController.nodes(for: level, in: parent)
        XCTAssertEqual(nodes.count, 2 + FolderTree.fileLimit + 1, "folders, capped files, one more row")
        XCTAssertEqual(nodes.last?.title, "25 more files")
    }

    /// A folder at or just over the cap shows everything. A "1 more files" row
    /// occupying the space the file itself would have taken helps nobody.
    func testTreeDoesNotAddAMoreRowForOneOrTwoExtraFiles() {
        let parent = URL(fileURLWithPath: "/soquel-tree", isDirectory: true)
        func files(_ n: Int) -> [URL] {
            (0..<n).map { parent.appendingPathComponent("f\($0)") }
        }

        for count in [0, 1, FolderTree.fileLimit, FolderTree.fileLimit + 1] {
            let level = FolderTree.split(folders: [], files: files(count))
            XCTAssertFalse(level.hasOverflow, "\(count) files should all show")
            XCTAssertEqual(level.files.count, count)
        }

        XCTAssertTrue(FolderTree.split(folders: [], files: files(FolderTree.fileLimit + 2)).hasOverflow)
    }

    /// The "more" row is not a file and has no URL, so nothing tries to
    /// navigate to it.
    func testTheMoreRowHasNoURL() {
        let node = SidebarNode(.treeMore(
            parent: URL(fileURLWithPath: "/soquel-tree", isDirectory: true),
            hidden: [URL(fileURLWithPath: "/soquel-tree/a")]
        ))
        XCTAssertNil(node.url)
        XCTAssertFalse(node.isExpandable, "it swaps itself out; it does not open")
        XCTAssertEqual(node.title, "1 more file")
    }

    /// A file row is a leaf. Giving it a disclosure triangle would offer to
    /// open something that cannot be opened.
    func testAFileInTheTreeIsALeafThatStillCarriesItsURL() {
        let url = URL(fileURLWithPath: "/soquel-tree/notes.txt")
        let node = SidebarNode(.treeFile(url))
        XCTAssertEqual(node.url, url)
        XCTAssertFalse(node.isExpandable)
        XCTAssertFalse(node.isGroup)
        XCTAssertEqual(node.title, "notes.txt")
    }

    /// The first fix only worked when the tree already had the folder loaded.
    ///
    /// Walking down to a folder the tree has not opened yet reads one level per
    /// background call, so reveal() re-enters itself several runloop turns after
    /// the click. The origin recorded at click time was cleared by then, so every
    /// step after the first moved the selection anyway — which is every real case,
    /// because a favourite usually points somewhere the tree has not been.
    func testTheClickedOriginSurvivesAnAsynchronousRevealWalk() {
        let item = SidebarItem(path: "/soquel-reveal/home/Work")
        let clicked = SidebarNode.Kind.pinned(item)

        // Step one: fresh walk, takes what was clicked.
        let first = SidebarViewController.carriedOrigin(
            fresh: true, clicked: clicked, carried: nil
        )
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: first))

        // Later steps: the click is over and navigationOrigin is nil, but the
        // carried value is what counts.
        let second = SidebarViewController.carriedOrigin(
            fresh: false, clicked: nil, carried: first
        )
        let third = SidebarViewController.carriedOrigin(
            fresh: false, clicked: nil, carried: second
        )
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: third),
                       "the highlight must still stay on the favourite three levels down")
    }

    /// A walk that did not start from a sidebar click leaves the selection
    /// alone, however many levels down it goes. The origin has to survive the
    /// whole walk for that to hold — it re-enters once per background load.
    func testAWalkFromElsewhereLeavesTheSelectionAloneAtEveryDepth() {
        var origin = SidebarViewController.carriedOrigin(fresh: true, clicked: nil, carried: nil)
        for _ in 0..<3 {
            origin = SidebarViewController.carriedOrigin(fresh: false, clicked: nil, carried: origin)
        }
        XCTAssertFalse(SidebarViewController.revealMovesSelection(navigatedFrom: origin))
    }

    /// A new click part-way through an old walk wins: it is a fresh walk.
    func testAFreshClickReplacesWhateverTheLastWalkCarried() {
        let folder = URL(fileURLWithPath: "/soquel-reveal/home", isDirectory: true)
        let carried = SidebarNode.Kind.pinned(SidebarItem(path: "/soquel-reveal/home/Work"))
        let origin = SidebarViewController.carriedOrigin(
            fresh: true, clicked: .treeFolder(folder), carried: carried
        )
        XCTAssertTrue(SidebarViewController.revealMovesSelection(navigatedFrom: origin))
    }

    /// Return renamed nothing because the editor was opened on column 0, which
    /// is the Git badge. The name column is second, and its position moves
    /// again as soon as anyone drags a header.
    func testRenameOpensTheNameColumnRatherThanTheFirstOne() {
        let ids = FileListViewController.defaultColumns.map(\.id)
        XCTAssertNotEqual(ids.first, "name", "the name column is not the first one")
        XCTAssertTrue(ids.contains("name"))
    }


    /// The first keystroke should replace the name and leave the type alone.
    func testRenameSelectsTheNameWithoutItsExtension() {
        XCTAssertEqual(InlineRenameEditor.selection(for: "notes.txt"), NSRange(location: 0, length: 5))
        XCTAssertEqual(InlineRenameEditor.selection(for: "archive.tar.gz"), NSRange(location: 0, length: 11))
    }

    /// A dotfile is all extension by NSString's reckoning, and selecting
    /// nothing would leave the caret in a field that looks unresponsive.
    func testRenameSelectsTheWholeNameWhenThereIsNoBase() {
        XCTAssertEqual(InlineRenameEditor.selection(for: ".gitignore"), NSRange(location: 0, length: 10))
        XCTAssertEqual(InlineRenameEditor.selection(for: "README"), NSRange(location: 0, length: 6))
    }

    /// An editor over a name near the right edge has to stay inside the view,
    /// or the end of the name is off screen while it is being typed.
    func testRenameEditorStaysInsideItsView() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let cell = NSRect(x: 240, y: 10, width: 50, height: 17)
        let frame = InlineRenameEditor.frame(
            for: cell, in: host, fitting: String(repeating: "x", count: 80), font: nil
        )
        XCTAssertLessThanOrEqual(frame.maxX, host.bounds.width)
        XCTAssertGreaterThanOrEqual(frame.width, cell.width)
        // Centred on the row it renames, not pushed up off it.
        XCTAssertEqual(frame.midY, cell.midY, accuracy: 0.01)
    }


    /// The tree came back closed on every launch: only user groups recorded
    /// their open state, and a tree folder has no group to record against.
    func testOpeningAFolderIsRemembered() {
        var open = SidebarViewController.remembering("/a", expanded: true, in: [])
        XCTAssertEqual(open, ["/a"])
        open = SidebarViewController.remembering("/a/b", expanded: true, in: open)
        XCTAssertEqual(open, ["/a", "/a/b"])
    }

    /// Shallow before deep, so replaying the list opens a parent before the
    /// child that needs the parent loaded first.
    func testRememberedFoldersComeBackParentFirst() {
        var open: [String] = []
        for path in ["/a/b/c", "/a", "/a/b"] {
            open = SidebarViewController.remembering(path, expanded: true, in: open)
        }
        XCTAssertEqual(open, ["/a", "/a/b", "/a/b/c"])
    }

    /// Closing a folder closes what is inside it. Leaving the descendants
    /// listed would spring them open again the next time the parent opened.
    func testClosingAFolderForgetsWhatWasInsideIt() {
        var open: [String] = []
        for path in ["/a", "/a/b", "/a/b/c", "/other"] {
            open = SidebarViewController.remembering(path, expanded: true, in: open)
        }
        let closed = SidebarViewController.remembering("/a", expanded: false, in: open)
        XCTAssertEqual(closed, ["/other"])
    }

    /// A sibling whose name starts with the same letters is not inside it.
    func testClosingAFolderLeavesItsNamesakeAlone() {
        var open: [String] = []
        for path in ["/a", "/ab", "/a/b"] {
            open = SidebarViewController.remembering(path, expanded: true, in: open)
        }
        let closed = SidebarViewController.remembering("/a", expanded: false, in: open)
        XCTAssertEqual(closed, ["/ab"])
    }

    /// Opening the same folder twice should not list it twice.
    func testOpeningTheSameFolderTwiceListsItOnce() {
        var open = SidebarViewController.remembering("/a", expanded: true, in: [])
        open = SidebarViewController.remembering("/a", expanded: true, in: open)
        XCTAssertEqual(open, ["/a"])
    }


    /// Selecting the Themes tab made the whole settings window wider, because a
    /// tab view sizes to its widest pane and a wrapping label with no width to
    /// wrap inside asks for all of it. Every pane is now pinned to the width it
    /// is given.
    func testASettingsPaneCannotMakeTheWindowWider() {
        let greedy = NSView()
        let label = NSTextField(labelWithString: String(repeating: "wide ", count: 200))
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        greedy.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: greedy.topAnchor),
            label.leadingAnchor.constraint(equalTo: greedy.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: greedy.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: greedy.bottomAnchor),
        ])

        let container = SettingsWindowController.paneContainer(greedy)
        container.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        container.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(greedy.frame.width, 620)
    }

}

// MARK: - Fuzz run, 19 August 2026

extension RegressionTests {
    /// F1. A branch name beginning with a dash reached git as an option. Git
    /// has `--output=<file>`, which truncates whatever it names, so one click
    /// on "Diff with Current" emptied a file of the user's. Proven against
    /// 1.1.0: an md5 of dc8ebb45… became d41d8cd9…, the empty file.
    func testRefsThatGitWouldReadAsOptionsAreRefused() {
        XCTAssertFalse(GitRepo.isSafeRef("--output=/tmp/victim.txt"))
        XCTAssertFalse(GitRepo.isSafeRef("--force"))
        XCTAssertFalse(GitRepo.isSafeRef("-D"))
        XCTAssertFalse(GitRepo.isSafeRef("--"))
        XCTAssertFalse(GitRepo.isSafeRef(""))
        XCTAssertTrue(GitRepo.isSafeRef("main"))
        XCTAssertTrue(GitRepo.isSafeRef("feature/dash-in-middle"))
    }

    /// F4. Every blank line was dropped, not just the trailing one, and the
    /// line numbers after it ran low by one per blank line. Patches that have
    /// been through anything that strips trailing whitespace hit this.
    func testBlankLinesKeepTheirPlaceAndTheirNumbering() {
        let patch = [
            "--- a/f", "+++ b/f", "@@ -1,6 +1,6 @@",
            " alpha", "", " bravo", "-charlie", "+CHARLIE", " delta", ""
        ].joined(separator: "\n")
        let lines = Diff.parse(unified: patch)

        let blank = lines.filter { $0.kind == .context && $0.text.isEmpty }
        XCTAssertEqual(blank.count, 1, "the blank line belongs in the output")
        XCTAssertEqual(blank.first?.oldNumber, 2)

        let removed = lines.first { $0.kind == .removed }
        XCTAssertEqual(removed?.text, "charlie")
        XCTAssertEqual(removed?.oldNumber, 4, "charlie is the fourth line, not the third")

        let delta = lines.last { $0.kind == .context }
        XCTAssertEqual(delta?.text, "delta")
        XCTAssertEqual(delta?.oldNumber, 5)

        XCTAssertFalse(lines.contains { $0.kind == .context && $0.text.isEmpty && $0.oldNumber == nil },
                       "no trailing empty row from the final newline")
    }

    /// F5. The blank-line test re-split the whole patch on every empty line,
    /// which made the parse quadratic — 8.3s for 16,000 lines, on the main
    /// thread. Four times the input must not cost sixteen times the work.
    func testParsingALargePatchStaysLinear() {
        func time(_ rows: Int) -> TimeInterval {
            let body = (0..<rows).map { _ in " code\n\n" }.joined()
            let text = "--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n" + body
            let start = Date()
            _ = Diff.parse(unified: text)
            return -start.timeIntervalSinceNow
        }
        _ = time(500)
        let small = time(2_000)
        let large = time(8_000)
        // Four times the rows. Linear is 4x; the old code was 16x and worse.
        XCTAssertLessThan(large, max(small * 8, 0.5),
                          "parse cost is growing faster than the input")
    }

    /// F6. `compare` refuses a file over 8 MB. Opening a .diff did not, so a
    /// 126 MB patch was read whole and parsed on the main thread.
    func testAPatchFileOverTheSizeLimitIsRefused() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let patch = folder.appendingPathComponent("huge.diff")
        // Sparse, so the test does not write 9 MB.
        let handle = FileManager.default.createFile(atPath: patch.path, contents: nil)
        XCTAssertTrue(handle)
        let file = try FileHandle(forWritingTo: patch)
        try file.truncate(atOffset: UInt64(Diff.sizeLimit) + 1)
        try file.close()

        let result = Diff.read(patch: patch)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.note, "huge.diff: Larger than 8 MB")
    }
}
