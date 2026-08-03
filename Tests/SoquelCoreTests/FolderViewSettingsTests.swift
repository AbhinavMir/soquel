import XCTest
@testable import SoquelCore

final class FolderViewSettingsTests: XCTestCase {
    private var wasEnabled = false

    override func setUp() {
        super.setUp()
        wasEnabled = FolderViewSettings.isEnabled
        FolderViewSettings.forgetAll()
        FolderViewSettings.isEnabled = true
    }

    override func tearDown() {
        FolderViewSettings.forgetAll()
        FolderViewSettings.isEnabled = wasEnabled
        super.tearDown()
    }

    private func folder(_ name: String) -> URL {
        URL(fileURLWithPath: "/soquel-views/\(name)", isDirectory: true)
    }

    func testEachFolderKeepsItsOwnViewMode() {
        FolderViewSettings.record(folder("Downloads"), viewMode: .list, sortOrder: nil)
        FolderViewSettings.record(folder("Pictures"), viewMode: .icon, sortOrder: nil)

        XCTAssertEqual(FolderViewSettings.viewMode(for: folder("Downloads")), .list)
        XCTAssertEqual(FolderViewSettings.viewMode(for: folder("Pictures")), .icon)
    }

    /// A folder never recorded falls back to the global setting rather than to
    /// an arbitrary default.
    func testAnUnknownFolderUsesTheGlobalSetting() {
        let was = Prefs.viewMode
        defer { Prefs.viewMode = was }
        Prefs.viewMode = .column
        XCTAssertEqual(FolderViewSettings.viewMode(for: folder("Never-visited")), .column)
    }

    /// Turned off, nothing is recorded and nothing is read back.
    func testNothingIsRememberedWhileTheFeatureIsOff() {
        FolderViewSettings.record(folder("Downloads"), viewMode: .icon, sortOrder: nil)
        FolderViewSettings.isEnabled = false
        XCTAssertNil(FolderViewSettings.entry(for: folder("Downloads")))

        FolderViewSettings.record(folder("Music"), viewMode: .icon, sortOrder: nil)
        FolderViewSettings.isEnabled = true
        XCTAssertNil(FolderViewSettings.entry(for: folder("Music")))
    }

    /// /tmp and /private/tmp are one folder, not two entries that disagree.
    func testASymlinkedPathIsTheSameFolder() {
        let viaSymlink = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let resolved = viaSymlink.resolvingSymlinksInPath()
        XCTAssertEqual(FolderViewSettings.identity(of: viaSymlink), FolderViewSettings.identity(of: resolved))
    }

    /// Years of use must not accumulate an entry per folder ever opened.
    func testTheOldestEntriesAreEvictedPastTheLimit() {
        var table: [String: FolderViewSettings.Entry] = [:]
        var order: [String] = []
        for i in 0..<(FolderViewSettings.limit + 10) {
            let id = "/folder/\(i)"
            table[id] = FolderViewSettings.Entry(viewMode: "list", sortOrder: nil)
            order.append(id)
        }

        let (trimmed, kept) = FolderViewSettings.evict(table: table, order: order)
        XCTAssertEqual(kept.count, FolderViewSettings.limit)
        XCTAssertEqual(trimmed.count, FolderViewSettings.limit)
        XCTAssertNil(trimmed["/folder/0"], "the oldest goes first")
        XCTAssertNotNil(trimmed["/folder/\(FolderViewSettings.limit + 9)"], "the newest stays")
    }

    func testForgettingOneLeavesTheRest() {
        FolderViewSettings.record(folder("A"), viewMode: .icon, sortOrder: nil)
        FolderViewSettings.record(folder("B"), viewMode: .column, sortOrder: nil)
        FolderViewSettings.forget(folder("A"))

        XCTAssertNil(FolderViewSettings.entry(for: folder("A")))
        XCTAssertEqual(FolderViewSettings.viewMode(for: folder("B")), .column)
    }
}
