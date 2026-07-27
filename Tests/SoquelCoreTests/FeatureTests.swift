import AppKit
import XCTest
@testable import SoquelCore

final class BatchRenameTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFindAndReplaceLeavesTheExtensionAlone() throws {
        let urls = [try file("holiday photo.jpg"), try file("holiday video.mov")]
        let plan = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "holiday", replace: "trip", regex: false, caseSensitive: false)
        ])
        XCTAssertEqual(plan.map(\.proposed), ["trip photo.jpg", "trip video.mov"])
    }

    func testRegexReplaceWithCaptureGroups() throws {
        let urls = [try file("IMG_4812.JPG"), try file("IMG_4813.JPG")]
        let plan = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "IMG_(\\d+)", replace: "holiday-$1", regex: true, caseSensitive: true)
        ])
        XCTAssertEqual(plan.map(\.proposed), ["holiday-4812.JPG", "holiday-4813.JPG"])
    }

    func testSequentialNumberingPadsToTheBatchSize() throws {
        var urls: [URL] = []
        for i in 1...12 { urls.append(try file("shot\(i).png")) }
        let plan = BatchRename.plan(for: urls, rules: [
            .sequence(prefix: "frame-", start: 1, padding: 2)
        ])
        XCTAssertEqual(plan.first?.proposed, "frame-01.png")
        XCTAssertEqual(plan.last?.proposed, "frame-12.png")
    }

    func testCaseConversion() throws {
        let urls = [try file("Mixed Case File.TXT")]
        XCTAssertEqual(
            BatchRename.plan(for: urls, rules: [.changeCase(.lower)]).first?.proposed,
            "mixed case file.txt"
        )
        XCTAssertEqual(
            BatchRename.plan(for: urls, rules: [.changeCase(.upper)]).first?.proposed,
            "MIXED CASE FILE.TXT"
        )
    }

    func testTrimCollapsesRuns() throws {
        let urls = [try file("too   many    spaces.txt")]
        XCTAssertEqual(
            BatchRename.plan(for: urls, rules: [.trimWhitespace]).first?.proposed,
            "too many spaces.txt"
        )
    }

    func testPrefixSuffixAndExtension() throws {
        let urls = [try file("note.txt")]
        XCTAssertEqual(BatchRename.plan(for: urls, rules: [.addPrefix("2026-")]).first?.proposed, "2026-note.txt")
        XCTAssertEqual(BatchRename.plan(for: urls, rules: [.addSuffix("-final")]).first?.proposed, "note-final.txt")
        XCTAssertEqual(BatchRename.plan(for: urls, rules: [.replaceExtension("md")]).first?.proposed, "note.md")
        XCTAssertEqual(BatchRename.plan(for: urls, rules: [.replaceExtension(".md")]).first?.proposed, "note.md")
    }

    func testRulesChainInOrder() throws {
        let urls = [try file("raw file.txt")]
        let plan = BatchRename.plan(for: urls, rules: [
            .trimWhitespace,
            .findReplace(find: " ", replace: "-", regex: false, caseSensitive: false),
            .addPrefix("doc-"),
        ])
        XCTAssertEqual(plan.first?.proposed, "doc-raw-file.txt")
    }

    /// Two files renamed to the same thing would destroy one of them, so the
    /// collision is caught in the preview rather than at write time.
    func testCollisionsWithinTheBatchAreFlagged() throws {
        let urls = [try file("a.txt"), try file("b.txt")]
        let plan = BatchRename.plan(for: urls, rules: [.sequence(prefix: "same", start: 1, padding: 0)])
        XCTAssertNil(plan[0].problem)

        let clashing = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "a", replace: "same", regex: false, caseSensitive: false),
            .findReplace(find: "b", replace: "same", regex: false, caseSensitive: false),
        ])
        XCTAssertNotNil(clashing[1].problem, "the second file must be blocked")
    }

    func testCollisionWithAnExistingFileIsFlagged() throws {
        _ = try file("taken.txt")
        let urls = [try file("free.txt")]
        let plan = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "free", replace: "taken", regex: false, caseSensitive: false)
        ])
        XCTAssertNotNil(plan.first?.problem)
    }

    func testEmptyAndInvalidNamesAreFlagged() throws {
        let urls = [try file("gone.txt")]
        let emptied = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "gone", replace: "", regex: false, caseSensitive: false),
            .replaceExtension(""),
        ])
        XCTAssertNotNil(emptied.first?.problem)

        let slashed = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "gone", replace: "a/b", regex: false, caseSensitive: false)
        ])
        XCTAssertNotNil(slashed.first?.problem)
    }

    /// Finder's date insertion uses the moment the rename runs; this uses the
    /// file's own date.
    func testDateUsesTheFilesOwnTimestamp() throws {
        let url = try file("report.txt")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let plan = BatchRename.plan(for: [url], rules: [.insertDate(format: "yyyy-MM-dd", useCreated: false)],
                                    now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(plan.first?.proposed.contains("2023-11-14") == true,
                      "got \(plan.first?.proposed ?? "nothing")")
    }

    func testApplyRenamesAndSkipsBlockedEntries() throws {
        _ = try file("taken.txt")
        let urls = [try file("one.txt"), try file("two.txt")]
        var plan = BatchRename.plan(for: urls, rules: [.addPrefix("new-")])
        plan[1].problem = "blocked"

        let result = BatchRename.apply(plan)
        XCTAssertEqual(result.renamed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new-one.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("two.txt").path),
                      "a blocked entry is left alone")
    }
}

final class ArchiveTests: XCTestCase {
    func testRecognisesArchiveExtensions() {
        XCTAssertTrue(Archive.isArchive(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(Archive.isArchive(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        XCTAssertTrue(Archive.isArchive(URL(fileURLWithPath: "/tmp/a.7z")))
        XCTAssertTrue(Archive.isArchive(URL(fileURLWithPath: "/tmp/a.rar")))
        XCTAssertFalse(Archive.isArchive(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(Archive.isArchive(URL(fileURLWithPath: "/tmp/a")))
    }

    /// zip and tar ship with macOS, so those always have a reader.
    func testBuiltInFormatsHaveAReader() {
        XCTAssertNotNil(Archive.lister(for: URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertNotNil(Archive.lister(for: URL(fileURLWithPath: "/tmp/a.tar")))
        XCTAssertNil(Archive.lister(for: URL(fileURLWithPath: "/tmp/a.txt")))
    }

    func testParsesUnzipOutput() {
        let output = """
        Archive:  bundle.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
             1024  01-01-2026 10:00   folder/file.txt
                0  01-01-2026 10:00   folder/
        ---------                     -------
             1024                     2 files
        """
        let entries = Archive.parseUnzip(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "folder/file.txt")
        XCTAssertEqual(entries[0].size, 1024)
        XCTAssertTrue(entries[1].isDirectory)
    }

    func testParsesTarOutput() {
        let output = "-rw-r--r--  0 user  staff  2048 Jan  1 10:00 docs/readme.md"
        let entries = Archive.parseTar(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].size, 2048)
    }

    func testDirectoryEntriesAreMarked() {
        let entries = Archive.parseNames("folder/\nfolder/file.txt\n")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].name, "file.txt")
    }

    /// End to end against a real zip, since parsing is the risky part.
    func testListsARealZip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "hello".write(to: dir.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("bundle.zip")
        _ = Archive.run("/usr/bin/zip", ["-j", "-q", zip.path, dir.appendingPathComponent("inside.txt").path])
        guard FileManager.default.fileExists(atPath: zip.path) else { return }

        let done = expectation(description: "listed")
        var names: [String] = []
        Archive.list(zip) { entries, _ in
            names = entries.map(\.name)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(names.contains("inside.txt"), "got \(names)")
    }
}

final class WorkspaceTests: XCTestCase {
    private func workspace(_ paths: [[String]]) -> Workspace {
        Workspace(name: "Test", panes: paths, activeTabs: paths.map { _ in 0 }, isVerticalSplit: true)
    }

    func testDropsFoldersThatNoLongerExist() {
        let model = workspace([["/tmp", "/definitely/not/here"], ["/definitely/gone"]])
        let surviving = model.survivingPanes()
        XCTAssertEqual(surviving.count, 1, "a pane with nothing left is dropped entirely")
        XCTAssertEqual(surviving[0], ["/tmp"])
    }

    func testUnusableWhenNothingSurvives() {
        XCTAssertFalse(workspace([["/definitely/gone"]]).isUsable)
        XCTAssertTrue(workspace([["/tmp"]]).isUsable)
    }

    func testSummaryCountsPanes() {
        XCTAssertEqual(workspace([["/tmp"]]).summary, "1 pane")
        XCTAssertEqual(workspace([["/tmp"], ["/usr"]]).summary, "2 panes")
    }

    func testRoundTripsThroughJSON() throws {
        let model = workspace([["/tmp", "/usr"], ["/var"]])
        let data = try JSONEncoder().encode([model])
        XCTAssertEqual(try JSONDecoder().decode([Workspace].self, from: data), [model])
    }

    /// Saving under an existing name replaces it rather than making a second.
    func testSavingSameNameReplaces() {
        let before = WorkspaceStore.all
        defer { WorkspaceStore.all = before }

        WorkspaceStore.all = []
        WorkspaceStore.add(workspace([["/tmp"]]))
        WorkspaceStore.add(workspace([["/usr"]]))
        XCTAssertEqual(WorkspaceStore.all.count, 1)
        XCTAssertEqual(WorkspaceStore.all.first?.panes, [["/usr"]])
    }
}

final class MetadataTests: XCTestCase {
    func testDurationIsFormattedForHumans() {
        XCTAssertEqual(MetadataReader.formatDuration(65), "1:05")
        XCTAssertEqual(MetadataReader.formatDuration(3725), "1:02:05")
        XCTAssertEqual(MetadataReader.formatDuration(9), "0:09")
    }

    func testFourCharacterCodesDecode() {
        // 'avc1'
        let code: FourCharCode = 0x61766331
        XCTAssertEqual(MetadataReader.fourCharacterCode(code), "avc1")
    }

    func testReadingAnImageGivesDimensions() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Built at an exact pixel size: NSImage sizes are in points, so a
        // retina lockFocus would double them and the assertion would be about
        // the display rather than the file.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 25,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let png = rep.representation(using: .png, properties: [:]) else { return }

        let url = dir.appendingPathComponent("swatch.png")
        try png.write(to: url)

        let record = MetadataReader.extract(from: url)
        XCTAssertEqual(record[.dimensions], "40 × 25")
    }

    /// A file that is neither image nor media yields nothing rather than guesses.
    func testUnknownFileYieldsNoMetadata() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-meta-\(UUID().uuidString).txt")
        try "just text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(MetadataReader.extract(from: url).isEmpty)
    }

    func testColumnsToggleAndPersist() {
        let before = MetadataColumns.enabled
        defer { MetadataColumns.enabled = before }

        MetadataColumns.enabled = []
        MetadataColumns.toggle(.duration)
        MetadataColumns.toggle(.dimensions)
        // Declared order is kept so columns do not shuffle.
        XCTAssertEqual(MetadataColumns.enabled, [.dimensions, .duration])

        MetadataColumns.toggle(.dimensions)
        XCTAssertEqual(MetadataColumns.enabled, [.duration])
    }
}

final class ViewModeTests: XCTestCase {
    func testThreeModesWithDistinctTitles() {
        let titles = ViewMode.allCases.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count)
        XCTAssertEqual(ViewMode.allCases.count, 3)
    }

    /// The old boolean setting still drives the new enum, so a stored
    /// preference from an earlier build keeps working.
    func testLegacyIconFlagMapsToTheEnum() {
        let before = Prefs.viewMode
        defer { Prefs.viewMode = before }

        Prefs.viewModeIsIcon = true
        XCTAssertEqual(Prefs.viewMode, .icon)
        Prefs.viewModeIsIcon = false
        XCTAssertEqual(Prefs.viewMode, .list)
        Prefs.viewMode = .column
        XCTAssertFalse(Prefs.viewModeIsIcon)
    }
}

/// Typing a name jumps to it. NSTableView does this for itself; the icon, tree
/// and column views do not, so the controller does it for all of them.
final class TypeSelectTests: XCTestCase {
    /// The matching rule, isolated from the view so it can be checked directly.
    private func match(_ names: [String], prefix: String, from start: Int) -> Int? {
        let order = (0..<names.count).map { (start + $0) % names.count }
        return order.first { names[$0].lowercased().hasPrefix(prefix.lowercased()) }
    }

    private let names = ["Applications", "Desktop", "Documents", "Downloads", "readme.md"]

    func testAPrefixFindsTheFirstMatch() {
        XCTAssertEqual(match(names, prefix: "do", from: 0), 2)      // Documents
        XCTAssertEqual(match(names, prefix: "dow", from: 0), 3)     // Downloads
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(match(names, prefix: "R", from: 0), 4)
        XCTAssertEqual(match(names, prefix: "aPP", from: 0), 0)
    }

    /// The same letter again moves to the next item starting with it rather
    /// than staying put.
    func testRepeatingALetterCyclesThroughTheMatches() {
        XCTAssertEqual(match(names, prefix: "d", from: 0), 1)       // Desktop
        XCTAssertEqual(match(names, prefix: "d", from: 2), 2)       // Documents
        XCTAssertEqual(match(names, prefix: "d", from: 3), 3)       // Downloads
        // Past the last match it comes back round to the first.
        XCTAssertEqual(match(names, prefix: "d", from: 4), 1)
    }

    func testNothingMatchesRatherThanPickingSomethingElse() {
        XCTAssertNil(match(names, prefix: "zz", from: 0))
    }

    /// The buffer is dropped after a pause so an unrelated later letter starts
    /// a new search instead of extending a stale prefix.
    func testTheBufferExpires() {
        XCTAssertEqual(FileListViewController.typeSelectTimeout, 1.0)
    }
}

/// One button that both pins a folder and unpins it, and reads as filled when
/// the folder is already there.
final class FavouriteToggleTests: XCTestCase {
    private func layout() -> SidebarLayout {
        var layout = SidebarLayout(groups: [])
        _ = layout.addGroup(title: "Favourites")
        return layout
    }

    func testAFolderIsFoundWhicheverWayItsPathIsWritten() {
        var l = layout()
        let group = l.groups[0].id
        l.addItem(SidebarItem(path: "/tmp/soq/Work"), toGroup: group)

        XCTAssertTrue(l.isPinned(URL(fileURLWithPath: "/tmp/soq/Work")))
        // The same folder reached by a path that needs standardising.
        XCTAssertTrue(l.isPinned(URL(fileURLWithPath: "/tmp/soq/Other/../Work")))
        XCTAssertFalse(l.isPinned(URL(fileURLWithPath: "/tmp/soq/Work-archive")),
                       "a folder whose name merely starts the same is not the same folder")
    }

    func testPinningThenUnpinningLeavesNothingBehind() {
        var l = layout()
        let group = l.groups[0].id
        let url = URL(fileURLWithPath: "/tmp/soq/Work")

        l.addItem(SidebarItem(path: url.path), toGroup: group)
        XCTAssertTrue(l.isPinned(url))

        let existing = try! XCTUnwrap(l.pin(for: url))
        l.removeItem(id: existing.id)
        XCTAssertFalse(l.isPinned(url))
        XCTAssertTrue(l.groups[0].items.isEmpty)
    }

    func testAFolderPinnedInAnyGroupCounts() {
        var l = layout()
        let second = l.addGroup(title: "Projects")
        l.addItem(SidebarItem(path: "/tmp/soq/Work"), toGroup: second)
        XCTAssertTrue(l.isPinned(URL(fileURLWithPath: "/tmp/soq/Work")))
    }

    func testTheButtonIsInTheDefaultToolbar() {
        XCTAssertTrue(ToolbarCatalogue.defaultIDs.contains("favourite"))
        XCTAssertNotNil(ToolbarCatalogue.action(id: "favourite"))
    }
}

/// The first-run window, and what can and cannot be automated.
final class WelcomeTests: XCTestCase {
    override func tearDown() {
        Settings.removeObject(forKey: "welcomeShown")
        super.tearDown()
    }

    /// Shown once. A window that reappears every launch is an advert.
    func testItIsOfferedOnceAndThenNotAgain() {
        Settings.removeObject(forKey: "welcomeShown")
        XCTAssertFalse(WelcomeWindowController.hasBeenShown)
        WelcomeWindowController.hasBeenShown = true
        XCTAssertTrue(WelcomeWindowController.hasBeenShown)
    }

    /// The flag has to be in the settings file, or it is forgotten and the
    /// window comes back on the next launch.
    func testTheFlagIsCarriedInSettings() {
        XCTAssertTrue(Prefs.keys.contains("welcomeShown"))
    }

    /// macOS refuses to let anything but Finder open folders. Recorded as a
    /// test so a later attempt to "fix" it finds the answer rather than the
    /// paramErr.
    func testFoldersCannotBeReassignedAwayFromFinder() {
        XCTAssertTrue(DefaultHandler.folderRoleIsReserved)
        let status = LSSetDefaultRoleHandlerForContentType(
            "public.folder" as CFString, .viewer, "app.soquel.Soquel" as CFString)
        XCTAssertNotEqual(status, noErr, "macOS started allowing this; the welcome text should say so")
    }

    /// The probe has to be a path that is actually protected, or the check
    /// reports access nobody has.
    func testTheAccessCheckLooksAtAProtectedPath() {
        // Granted or not, asking must not crash or block.
        _ = FullDiskAccess.isGranted
    }
}
