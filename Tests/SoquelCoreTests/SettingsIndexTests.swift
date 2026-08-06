import XCTest
@testable import SoquelCore

final class SettingsIndexTests: XCTestCase {
    /// People search for what they want to change, not the word the interface
    /// happens to use for it.
    func testTheWordSomebodyWouldActuallyType() {
        XCTAssertTrue(SettingsIndex.search("transparent").contains { $0.title == "Window opacity" })
        XCTAssertTrue(SettingsIndex.search("wallpaper").contains { $0.pane == "window" })
        XCTAssertTrue(SettingsIndex.search("vim").contains { $0.pane == "keyboard" })
        XCTAssertTrue(SettingsIndex.search("duti").contains { $0.pane == "applications" })
        XCTAssertTrue(SettingsIndex.search("windows 95").contains { $0.pane == "themes" })
    }

    /// Every word, not any: "dark colour" narrows rather than widening.
    func testEveryWordHasToMatch() {
        let both = SettingsIndex.search("dark colour")
        XCTAssertFalse(both.isEmpty)
        XCTAssertTrue(both.allSatisfy { $0.pane == "appearance" })

        XCTAssertTrue(SettingsIndex.search("transparent duti").isEmpty,
                      "nothing is both, so nothing matches")
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertTrue(SettingsIndex.search("").isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ").isEmpty)
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(SettingsIndex.search("zzzqqq").isEmpty)
    }

    /// Every entry points at a pane that exists, or the result goes nowhere.
    func testEveryEntryPointsAtARealPane() {
        let panes = ["appearance", "window", "themes", "keyboard", "applications", "updates"]
        for entry in SettingsIndex.all {
            XCTAssertTrue(panes.contains(entry.pane), "\(entry.title) → \(entry.pane)")
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.keywords.isEmpty, entry.title)
        }
    }

    /// Every pane is reachable by search, so none is a place you can only find
    /// by clicking every tab.
    func testEveryPaneIsFindable() {
        let reachable = Set(SettingsIndex.all.map(\.pane))
        for pane in ["appearance", "window", "themes", "keyboard", "applications", "updates"] {
            XCTAssertTrue(reachable.contains(pane), pane)
        }
    }

    func testThePanesOfAMatchComeBackInOrderWithoutRepeats() {
        let panes = SettingsIndex.panes(matching: "colour")
        XCTAssertEqual(Set(panes).count, panes.count, "no repeats")
    }
}
