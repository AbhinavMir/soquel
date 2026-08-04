import AppKit
import XCTest
@testable import SoquelCore

/// Exercises the real PaneViewController rather than the index arithmetic
/// alone: tabs are added, switched, and closed through the same calls the
/// buttons make.
final class MultiTabTests: XCTestCase {
    private var root: URL!
    private var pane: PaneViewController!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-tabs-\(UUID().uuidString)", isDirectory: true)
        for name in ["one", "two", "three", "four"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        pane = PaneViewController(url: folder("one"))
        _ = pane.view          // force loadView so the tab bar exists
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func folder(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private var names: [String] {
        pane.tabs.map(\.url.lastPathComponent)
    }

    func testAPaneStartsWithOneTab() {
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(names, ["one"])
    }

    func testAddingTabsActivatesTheNewOne() {
        pane.addTab(url: folder("two"))
        pane.addTab(url: folder("three"))

        XCTAssertEqual(names, ["one", "two", "three"])
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "three")
    }

    /// A tab added without activating it leaves the front one alone.
    func testATabCanBeAddedInTheBackground() {
        pane.addTab(url: folder("two"), activate: false)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "one")
    }

    func testSwitchingTabsChangesWhatThePaneShows() {
        pane.addTab(url: folder("two"))
        pane.addTab(url: folder("three"))

        pane.selectTab(at: 0)
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "one")
        pane.selectTab(at: 2)
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "three")
    }

    func testNextAndPreviousWrapAround() {
        pane.addTab(url: folder("two"))
        pane.addTab(url: folder("three"))
        pane.selectTab(at: 2)

        pane.nextTab()
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "one", "past the end comes back to the start")
        pane.previousTab()
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "three")
    }

    /// The ✕ on a tab closes that tab, not whichever one happens to be active.
    func testTheCloseButtonClosesTheTabItIsOn() {
        pane.addTab(url: folder("two"))
        pane.addTab(url: folder("three"))
        pane.selectTab(at: 2)

        XCTAssertTrue(pane.closeTab(at: 0))
        XCTAssertEqual(names, ["two", "three"])
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "three",
                       "closing a tab to the left keeps the same folder in front")
    }

    func testClosingTheActiveTabFallsToItsNeighbour() {
        pane.addTab(url: folder("two"))
        pane.addTab(url: folder("three"))
        pane.selectTab(at: 1)

        XCTAssertTrue(pane.closeTab(at: 1))
        XCTAssertEqual(names, ["one", "three"])
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "three")
    }

    /// The last tab is the pane. Closing it is the window's decision, so the
    /// pane refuses and says so.
    func testTheLastTabWillNotClose() {
        XCTAssertFalse(pane.closeActiveTab())
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertFalse(pane.closeTab(at: 0))
    }

    func testClosingOutOfRangeDoesNothing() {
        pane.addTab(url: folder("two"))
        XCTAssertFalse(pane.closeTab(at: 9))
        XCTAssertEqual(pane.tabs.count, 2)
    }

    /// Four tabs open, closed back down to one, without losing track of which
    /// is in front.
    func testOpeningAndClosingSeveralKeepsTheFrontTabRight() {
        for name in ["two", "three", "four"] { pane.addTab(url: folder(name)) }
        XCTAssertEqual(names, ["one", "two", "three", "four"])

        pane.selectTab(at: 1)
        XCTAssertTrue(pane.closeTab(at: 3))
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "two")
        XCTAssertTrue(pane.closeTab(at: 0))
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "two")
        XCTAssertTrue(pane.closeTab(at: 1))
        XCTAssertEqual(names, ["two"])
        XCTAssertFalse(pane.closeTab(at: 0))
    }

    /// A pane cannot have no tabs, so the bar always has something in it and
    /// never hides. It used to appear only at two tabs, which took the plus
    /// away from the one person most likely to want it.
    func testTheSingleTabStillShowsAndCannotBeClosed() {
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertFalse(pane.closeTab(at: 0), "the last tab is the pane")
        XCTAssertEqual(pane.currentURL?.lastPathComponent, "one")
    }

    /// Closing back down to one leaves that tab in place rather than an empty
    /// pane.
    func testClosingDownToOneStopsThere() {
        pane.addTab(url: folder("two"))
        XCTAssertTrue(pane.closeTab(at: 0))
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertFalse(pane.closeTab(at: 0))
        XCTAssertEqual(pane.tabs.count, 1)
    }
}

/// The pane asks its list what mode it is in, so the list must know before the
/// pane asks. It did not, and the pane hid the column browser while the list
/// hid its own table — an empty pane, no rename, and no double-click.
final class ViewModeFreshnessTests: XCTestCase {
    private var root: URL!
    private var list: FileListViewController!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        list = FileListViewController(url: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        Prefs.viewMode = .list
        super.tearDown()
    }

    /// refreshMode works without the view ever having been loaded, which is
    /// the case applyViewMode returned early for.
    func testTheModeIsCorrectBeforeTheViewLoads() {
        XCTAssertFalse(list.isViewLoaded)
        Prefs.viewMode = .column
        list.refreshMode()
        XCTAssertEqual(list.mode, .column)
    }

    func testTheModeFollowsEveryChange() {
        for mode in [ViewMode.icon, .column, .list] {
            Prefs.viewMode = mode
            list.refreshMode()
            XCTAssertEqual(list.mode, mode)
        }
    }

    /// A pane decides whether to show the column browser from this, so a stale
    /// answer draws an empty pane.
    func testAStaleModeWouldDisagreeWithThePreference() {
        Prefs.viewMode = .list
        list.refreshMode()
        Prefs.viewMode = .column
        XCTAssertNotEqual(list.mode, Prefs.viewMode, "stale until refreshed")
        list.refreshMode()
        XCTAssertEqual(list.mode, Prefs.viewMode)
    }
}
