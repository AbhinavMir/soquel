import AppKit
import XCTest
@testable import SoquelCore

final class BackgroundConfigTests: XCTestCase {
    func testDefaultIsNoImageAtAReadableOpacity() {
        let config = BackgroundConfig.none
        XCTAssertNil(config.imageURL)
        XCTAssertLessThanOrEqual(config.opacity, 0.3, "the default must not drown the file list")
    }

    /// A stored value outside 0...1 must not make the list unreadable.
    func testOpacityIsClamped() {
        var config = BackgroundConfig.none
        config.opacity = 4.2
        XCTAssertEqual(config.effectiveOpacity, 1)
        config.opacity = -3
        XCTAssertEqual(config.effectiveOpacity, 0)
    }

    func testTildePathsExpand() {
        var config = BackgroundConfig.none
        config.imagePath = "~/Pictures/wall.png"
        XCTAssertEqual(config.imageURL?.path,
                       FileManager.default.homeDirectoryForCurrentUser.path + "/Pictures/wall.png")
    }

    func testEmptyPathMeansNoImage() {
        var config = BackgroundConfig.none
        config.imagePath = ""
        XCTAssertNil(config.imageURL)
    }

    func testRoundTripsThroughTheThemeFile() throws {
        let config = ThemeConfig(
            light: ["accent": "#B3541E"],
            dark: [:],
            background: BackgroundConfig(imagePath: "/tmp/x.png", opacity: 0.4, fit: .tile, includeSidebar: true)
        )
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ThemeConfig.self, from: data), config)
    }

    /// A theme.json written before backgrounds existed must still load.
    func testThemeFileWithoutABackgroundStillDecodes() throws {
        let json = "{\"light\":{\"accent\":\"#B3541E\"},\"dark\":{}}"
        let config = try JSONDecoder().decode(ThemeConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.background)
        XCTAssertEqual(config.light["accent"], "#B3541E")
    }

    func testMissingImageFileYieldsNoImage() {
        let cache = BackgroundImageCache()
        XCTAssertNil(cache.image(for: URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID()).png")))
    }
}

final class ExternalAppTests: XCTestCase {
    override func tearDown() {
        Prefs.terminalBundleID = nil
        Prefs.editorBundleID = nil
        super.tearDown()
    }

    func testTerminalIsAlwaysOffered() {
        // Terminal.app ships with macOS, so there is always at least one.
        XCTAssertFalse(ExternalApps.installedTerminals.isEmpty)
        XCTAssertNotNil(ExternalApps.preferredTerminal())
    }

    func testChoosingATerminalSticks() {
        guard ExternalApps.installedTerminals.count >= 1 else { return }
        let choice = ExternalApps.installedTerminals[0]
        Prefs.terminalBundleID = choice.bundleID
        XCTAssertEqual(ExternalApps.preferredTerminal()?.bundleID, choice.bundleID)
    }

    /// A remembered terminal that has since been uninstalled must not leave the
    /// command dead; it falls back to one that exists.
    func testUninstalledChoiceFallsBack() {
        Prefs.terminalBundleID = "com.example.not-installed"
        let chosen = ExternalApps.preferredTerminal()
        XCTAssertNotNil(chosen)
        XCTAssertNotEqual(chosen?.bundleID, "com.example.not-installed")
    }

    func testEveryEntryHasADistinctBundleIdentifier() {
        let ids = (ExternalApps.terminals + ExternalApps.editors).map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}

final class EmptyStateTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// macOS returns an empty listing rather than an error for these, so the
    /// message must not assert the folder is empty.
    func testProtectedFoldersAreRecognised() {
        for name in ["Desktop", "Documents", "Downloads"] {
            XCTAssertTrue(
                FileListViewController.isPrivacyProtected(home.appendingPathComponent(name)),
                "\(name) is gated by macOS privacy"
            )
        }
        XCTAssertTrue(FileListViewController.isPrivacyProtected(URL(fileURLWithPath: "/Volumes/Backup")))
        XCTAssertTrue(
            FileListViewController.isPrivacyProtected(home.appendingPathComponent("Downloads/nested")),
            "folders inside a gated folder are gated too"
        )
    }

    func testOrdinaryFoldersAreNot() {
        XCTAssertFalse(FileListViewController.isPrivacyProtected(home))
        XCTAssertFalse(FileListViewController.isPrivacyProtected(home.appendingPathComponent("Code")))
        XCTAssertFalse(FileListViewController.isPrivacyProtected(URL(fileURLWithPath: "/usr/local")))
        XCTAssertFalse(FileListViewController.isPrivacyProtected(URL(fileURLWithPath: "/Volumes")))
    }

    func testMessageNamesThePermissionPossibility() {
        let gated = FileListViewController.emptyMessage(for: home.appendingPathComponent("Downloads"))
        XCTAssertTrue(gated.contains("blocking access"))
        XCTAssertTrue(gated.contains("Full Disk Access"))

        let ordinary = FileListViewController.emptyMessage(for: home.appendingPathComponent("Code"))
        XCTAssertEqual(ordinary, "This folder is empty")
    }
}
