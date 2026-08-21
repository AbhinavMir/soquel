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

/// Findings from the fuzz run of 21 August 2026.
extension FinderTakeoverTests {
    /// A version string can arrive from the advisory list, which is fetched
    /// over the network. It used to be pasted straight into a URL and into two
    /// file paths, so "../../../../tmp/evil" put the staging copy at
    /// /tmp/evil-incoming.app, outside the folder holding the application.
    func testOnlyARealVersionCanReachTheFilesystem() {
        for rubbish in ["../../../../tmp/evil", "../../Users/x/Desktop/y", "..", "/etc/passwd",
                        "1.1.1/../..", "", " ", "a b", "$(whoami)", "nightly"] {
            XCTAssertNil(Installer.downloadURL(for: rubbish),
                         "\(rubbish.debugDescription) was accepted as a version")
        }
        XCTAssertEqual(Installer.downloadURL(for: "1.2.1")?.absoluteString,
            "https://github.com/AbhinavMir/soquel/releases/download/v1.2.1/Soquel-1.2.1.dmg")
        // A version that parses is normalised before it is used, so trailing
        // rubbish is dropped rather than carried into a URL or a file path.
        XCTAssertEqual(Installer.downloadURL(for: "v1.2")?.absoluteString,
            "https://github.com/AbhinavMir/soquel/releases/download/v1.2.0/Soquel-1.2.0.dmg")
        for messy in ["1.1.1\n", "1.1.1-beta2", " 1.1.1 "] {
            XCTAssertEqual(Installer.downloadURL(for: messy)?.absoluteString,
                "https://github.com/AbhinavMir/soquel/releases/download/v1.1.1/Soquel-1.1.1.dmg",
                "\(messy.debugDescription) was not normalised")
        }
    }

    /// The progress dialog's Cancel button used to be decoration: the alert
    /// closed, the download carried on, and the application was replaced.
    func testAnInstallCanActuallyBeCancelled() {
        let done = expectation(description: "install reports back")
        var outcome: Swift.Result<String, Error>?
        let job = Installer.install(version: "1.2.1") { _ in } completion: { result in
            outcome = result
            done.fulfill()
        }
        job.cancel()
        XCTAssertTrue(job.isCancelled)
        wait(for: [done], timeout: 30)

        guard case .failure(let error)? = outcome else {
            return XCTFail("a cancelled install reported success")
        }
        // Either the cancellation was seen, or URLSession reported the
        // cancelled task. Both mean nothing was replaced.
        let failure = error as? Installer.Failure
        let cancelled = failure == .cancelled
            || (error as NSError).code == NSURLErrorCancelled
            || { if case .download = failure { return true } else { return false } }()
        XCTAssertTrue(cancelled, "cancelling gave \(error)")
    }

    /// A version that is not a version must fail before any network or disk
    /// work starts, and must say so.
    func testAnUnusableVersionFailsImmediately() {
        let done = expectation(description: "reports back")
        var outcome: Swift.Result<String, Error>?
        Installer.install(version: "../../etc") { _ in } completion: {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .failure(let error)? = outcome else {
            return XCTFail("a bogus version was accepted")
        }
        XCTAssertEqual(error as? Installer.Failure, .unusableVersion("../../etc"))
    }
}
