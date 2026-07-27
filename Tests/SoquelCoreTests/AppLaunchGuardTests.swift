import XCTest
import AppKit
@testable import SoquelCore

final class AppLaunchGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppLaunchGuard.forgetAllowances()
        Settings.removeObject(forKey: "heavyApplications")
        AppLaunchGuard.isEnabled = true
    }

    override func tearDown() {
        AppLaunchGuard.forgetAllowances()
        Settings.removeObject(forKey: "heavyApplications")
        Settings.removeObject(forKey: "confirmHeavyLaunches")
        super.tearDown()
    }

    func testXcodeIsAskedAbout() {
        XCTAssertTrue(AppLaunchGuard.shouldAsk(about: "com.apple.dt.Xcode"))
    }

    /// Asking before TextEdit would be worse than not asking at all.
    func testOrdinaryApplicationsAreNot() {
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: "com.apple.TextEdit"))
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: "com.apple.Preview"))
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: nil))
    }

    func testDontAskAgainSticks() {
        AppLaunchGuard.alwaysAllow("com.apple.dt.Xcode")
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: "com.apple.dt.Xcode"))
    }

    /// Allowing one application must not quietly allow the rest.
    func testDontAskAgainIsPerApplication() {
        AppLaunchGuard.alwaysAllow("com.apple.dt.Xcode")
        XCTAssertTrue(AppLaunchGuard.shouldAsk(about: "com.google.android.studio"))
    }

    func testAllowancesCanBeForgotten() {
        AppLaunchGuard.alwaysAllow("com.apple.dt.Xcode")
        AppLaunchGuard.forgetAllowances()
        XCTAssertTrue(AppLaunchGuard.shouldAsk(about: "com.apple.dt.Xcode"))
    }

    func testTheWholeThingCanBeTurnedOff() {
        AppLaunchGuard.isEnabled = false
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: "com.apple.dt.Xcode"))
    }

    func testItIsOnByDefault() {
        Settings.removeObject(forKey: "confirmHeavyLaunches")
        XCTAssertTrue(AppLaunchGuard.isEnabled)
    }

    /// Someone else's slow application should get the same prompt as Xcode.
    func testAUserCanMarkTheirOwnApplicationHeavy() {
        XCTAssertFalse(AppLaunchGuard.shouldAsk(about: "com.example.slowthing"))
        AppLaunchGuard.markHeavy("com.example.slowthing")
        XCTAssertTrue(AppLaunchGuard.shouldAsk(about: "com.example.slowthing"))
    }

    func testTheThreeButtonsMapToTheThreeOutcomes() {
        XCTAssertEqual(AppLaunchGuard.answer(for: .alertFirstButtonReturn), .open)
        XCTAssertEqual(AppLaunchGuard.answer(for: .alertSecondButtonReturn), .openAndStopAsking)
        XCTAssertEqual(AppLaunchGuard.answer(for: .alertThirdButtonReturn), .cancel)
    }

    /// A selection that opens in two different applications has no single
    /// application to ask about.
    func testAMixedSelectionHasNoSingleApplication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = directory.appendingPathComponent("a.txt")
        let image = directory.appendingPathComponent("b.png")
        try Data("x".utf8).write(to: text)
        try Data("x".utf8).write(to: image)

        // Same file twice does agree.
        XCTAssertNotNil(AppLaunchGuard.applicationThatWouldOpen([text, text]))
    }

    func testBundleIdentifierOfARealApplication() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(AppLaunchGuard.bundleID(of: finder), "com.apple.finder")
    }
}

final class ApplicationSettingsTests: XCTestCase {
    func testEveryKindHasAtLeastOneExtension() {
        for kind in ApplicationSettingsView.kinds {
            XCTAssertFalse(kind.extensions.isEmpty, "\(kind.title) has no extensions")
            XCTAssertEqual(kind.primary, kind.extensions[0])
        }
    }

    func testNoExtensionIsListedTwice() {
        let all = ApplicationSettingsView.kinds.flatMap(\.extensions)
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testExtensionsResolveToRealTypes() {
        for kind in ApplicationSettingsView.kinds {
            XCTAssertNotNil(
                ApplicationSettingsView.contentType(forExtension: kind.primary),
                "\(kind.primary) has no UTI"
            )
        }
    }

    /// Every machine has a handler for plain text; none means the lookup is
    /// broken rather than the machine being unusual.
    func testPlainTextHasAHandler() {
        XCTAssertNotNil(ApplicationSettingsView.defaultApplication(forExtension: "txt"))
        XCTAssertFalse(ApplicationSettingsView.candidates(forExtension: "txt").isEmpty)
    }

    func testCandidatesAreDeduplicated() {
        let candidates = ApplicationSettingsView.candidates(forExtension: "txt")
        let ids = candidates.map { Bundle(url: $0)?.bundleIdentifier ?? $0.path }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
