import XCTest
@testable import SoquelCore

/// What macOS actually permits, asserted rather than assumed.
final class FinderTakeoverTests: XCTestCase {

    /// The finding the whole design rests on. If a future macOS starts allowing
    /// this, the settings pane can offer the simpler route and this test says so
    /// by failing.
    func testFinderStillOwnsTheFolderType() {
        // Deliberately a read, not a write. An earlier version of this test
        // called LSSetDefaultRoleHandlerForContentType to prove the refusal,
        // which changed the real LaunchServices database on whatever machine
        // ran the suite and put "which application should open this?" dialogs
        // in front of the user. The refusal is recorded in
        // docs/RESEARCH-replacing-finder.md, measured once, by hand.
        //
        // No test in this file may write to LaunchServices, change a default
        // handler, quit Finder, or touch com.apple.finder's preferences.
        XCTAssertNotEqual(FinderTakeover.defaultHandler(for: "public.folder"),
                          Bundle.main.bundleIdentifier)
    }

    /// The pane must never claim to own folders while macOS says otherwise.
    func testFolderClaimReportsTheTruth() {
        let claimed = FinderTakeover.canClaimFolders()
        let handler = FinderTakeover.defaultHandler(for: "public.folder")
        XCTAssertEqual(claimed, handler == Bundle.main.bundleIdentifier)
    }

    /// The script asks for the selection before the window, because a reveal
    /// sets the selection and a plain launch only has a window.
    func testTheScriptAsksForTheSelectionFirst() {
        let script = FinderTakeover.script
        let selection = script.range(of: "get selection")
        let window = script.range(of: "target of front window")
        XCTAssertNotNil(selection)
        XCTAssertNotNil(window)
        XCTAssertLessThan(selection!.lowerBound, window!.lowerBound)
        XCTAssertTrue(script.contains("POSIX path"))
    }

    /// An unanswered permission prompt blocks its caller. During testing that
    /// froze every AppleEvent on the machine, so the ask must time out.
    func testAskingFinderGivesUpRatherThanHanging() {
        XCTAssertGreaterThan(FinderTakeover.askTimeout, 0)
        XCTAssertLessThanOrEqual(FinderTakeover.askTimeout, 3,
            "a longer wait holds Finder open in front of the user")
    }

    /// Reading permission must not be what puts the prompt up. Only the button does.
    func testCheckingPermissionDoesNotPrompt() {
        // Passing false for askUserIfNeeded is the whole point; calling it here
        // would hang the suite if it prompted.
        _ = FinderTakeover.hasAutomationPermission()
    }

    /// Turning the watcher on and off must leave nothing behind.
    func testTheWatcherStartsAndStopsCleanly() {
        let wasOn = FinderTakeover.catchesFinder
        defer { FinderTakeover.catchesFinder = wasOn }

        FinderTakeover.stop()
        XCTAssertFalse(FinderTakeover.isRunning)
        FinderTakeover.start()
        XCTAssertTrue(FinderTakeover.isRunning)
        FinderTakeover.start()
        XCTAssertTrue(FinderTakeover.isRunning, "starting twice must not double-register")
        FinderTakeover.stop()
        XCTAssertFalse(FinderTakeover.isRunning)
    }

    /// The two switches that live only in Soquel's own settings reset cleanly.
    ///
    /// `giveBackToFinder()` itself is not called here: it also resets
    /// `opensVolumes` and the desktop, which write to LaunchServices and to
    /// com.apple.finder, and a test must not reach outside the project to do
    /// that. Those two are exercised by hand.
    func testTheSoquelOwnedSwitchesResetCleanly() {
        let caught = FinderTakeover.catchesFinder
        let followed = FinderTakeover.followsFinder
        defer {
            FinderTakeover.catchesFinder = caught
            FinderTakeover.followsFinder = followed
        }

        FinderTakeover.catchesFinder = true
        FinderTakeover.followsFinder = true
        XCTAssertTrue(FinderTakeover.isRunning)

        FinderTakeover.catchesFinder = false
        FinderTakeover.followsFinder = false
        XCTAssertFalse(FinderTakeover.catchesFinder)
        XCTAssertFalse(FinderTakeover.followsFinder)
        XCTAssertFalse(FinderTakeover.isRunning)
    }
}
