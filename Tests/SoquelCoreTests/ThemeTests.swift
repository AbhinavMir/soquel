import AppKit
import XCTest
@testable import SoquelCore

final class ThemeTests: XCTestCase {
    private func hex(_ color: NSColor?) -> String? { color?.hexString }

    override func setUp() {
        super.setUp()
        try? ThemeConfig.removeFile()
        Theme.config = .empty
    }

    override func tearDown() {
        try? ThemeConfig.removeFile()
        Theme.config = .empty
        super.tearDown()
    }

    // MARK: - Hex parsing

    func testParsesSixDigitHexWithAndWithoutHash() {
        XCTAssertEqual(hex(NSColor(hexString: "#1A6669")), "#1A6669")
        XCTAssertEqual(hex(NSColor(hexString: "1a6669")), "#1A6669")
        XCTAssertEqual(hex(NSColor(hexString: "  #1A6669  ")), "#1A6669")
    }

    func testParsesShorthandAndAlpha() {
        XCTAssertEqual(hex(NSColor(hexString: "#0AF")), "#00AAFF")
        XCTAssertEqual(hex(NSColor(hexString: "#1A666980")), "#1A666980")
    }

    /// A colour that cannot be parsed must be rejected, not guessed at. A
    /// wrong-but-present colour is worse than falling back to the default.
    func testRejectsMalformedHex() {
        for bad in ["", "#", "#12345", "#GGGGGG", "teal", "#1A6669FF00", "rgb(1,2,3)"] {
            XCTAssertNil(NSColor(hexString: bad), "\(bad) must not parse")
        }
    }

    func testHexRoundTrip() {
        for value in ["#000000", "#FFFFFF", "#1A6669", "#6BC2C6", "#1A666924"] {
            XCTAssertEqual(hex(NSColor(hexString: value)), value)
        }
    }

    // MARK: - Overrides

    func testOverrideReplacesOnlyTheGivenSlotAndAppearance() {
        let config = ThemeConfig(light: ["accent": "#B3541E"], dark: [:])
        XCTAssertEqual(hex(config.color(for: .accent, dark: false)), "#B3541E")
        XCTAssertNil(config.color(for: .accent, dark: true), "dark must fall back")
        XCTAssertNil(config.color(for: .danger, dark: false), "other slots untouched")
    }

    func testMalformedOverrideFallsBackToBuiltIn() {
        let config = ThemeConfig(light: ["accent": "not-a-colour"], dark: [:])
        XCTAssertNil(config.color(for: .accent, dark: false))
    }

    func testResolvedUsesBuiltInWithoutOverrides() {
        let previous = Theme.config
        defer { Theme.config = previous }
        Theme.config = .empty
        XCTAssertEqual(hex(Theme.resolved(.accent, dark: false)), "#002780")
        XCTAssertEqual(hex(Theme.resolved(.accent, dark: true)), "#669CFF")
    }

    func testResolvedPrefersOverride() {
        let previous = Theme.config
        defer { Theme.config = previous }
        Theme.config = ThemeConfig(light: ["accent": "#B3541E"], dark: ["accent": "#E8A87C"])
        XCTAssertEqual(hex(Theme.resolved(.accent, dark: false)), "#B3541E")
        XCTAssertEqual(hex(Theme.resolved(.accent, dark: true)), "#E8A87C")
        // A slot the user did not set keeps the designed value.
        XCTAssertEqual(hex(Theme.resolved(.danger, dark: false)), "#A52E25")
    }

    // MARK: - File format

    func testConfigRoundTripsThroughJSON() throws {
        let config = ThemeConfig(light: ["accent": "#B3541E"], dark: ["accent": "#E8A87C"])
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ThemeConfig.self, from: data), config)
    }

    /// Goes through Theme.writeTemplate and reads the file back. Building the
    /// expected dictionary locally would pass whatever writeTemplate did.
    func testTemplateContainsEverySlotForBothAppearances() throws {
        try Theme.writeTemplate()
        let written = try ThemeConfig.load()

        for slot in ThemeConfig.Slot.allCases {
            XCTAssertNotNil(written.light[slot.rawValue], "\(slot.rawValue) missing from light")
            XCTAssertNotNil(written.dark[slot.rawValue], "\(slot.rawValue) missing from dark")
        }
        // Every written value must parse back, or the template teaches a format
        // the reader cannot use.
        for value in Array(written.light.values) + Array(written.dark.values) {
            XCTAssertNotNil(NSColor(hexString: value), "\(value) is not re-readable")
        }
    }

    /// "Reveal theme.json" writes the file to show it to the user. Writing the
    /// shipped palette instead of theirs discards every colour they had set.
    func testTemplateWritesTheColoursInForceNotTheBuiltInOnes() throws {
        Theme.apply(ThemeConfig(light: ["accent": "#B3541E"], dark: ["accent": "#E8A87C"]))
        try Theme.writeTemplate()

        let written = try ThemeConfig.load()
        XCTAssertEqual(written.light["accent"], "#B3541E")
        XCTAssertEqual(written.dark["accent"], "#E8A87C")
        // A slot never touched still comes out at its designed value.
        XCTAssertEqual(written.light["danger"], Theme.builtIn(.danger, dark: false).hexString)
    }

    /// Same action must not throw away the background image either.
    func testTemplateKeepsTheConfiguredBackground() throws {
        Theme.setBackground(BackgroundConfig(
            imagePath: "/tmp/soquel-wallpaper.png", opacity: 0.4,
            fit: .tile, includeSidebar: true))
        try Theme.writeTemplate()

        let written = try ThemeConfig.load()
        XCTAssertEqual(written.background?.imagePath, "/tmp/soquel-wallpaper.png")
        XCTAssertEqual(written.background?.opacity, 0.4)
        XCTAssertEqual(written.background?.fit, .tile)
        XCTAssertTrue(written.background?.includeSidebar ?? false)
    }

    // MARK: - One source of truth

    func testResettingClearsTheOverrides() throws {
        Theme.apply(ThemeConfig(light: ["accent": "#B3541E"], dark: [:]))
        try Theme.reset()
        XCTAssertTrue(Theme.config.light.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ThemeConfig.fileURL.path))
    }

    /// The suite applies and resets themes constantly. Doing that to the real
    /// file destroys the colours of whoever is running the tests.
    func testTestsDoNotWriteToTheRealSupportFolder() {
        XCTAssertFalse(ThemeConfig.directoryURL.path.hasSuffix("Application Support/Soquel"))
        XCTAssertFalse(ThemeConfig.fileURL.path.hasSuffix("Application Support/Soquel/theme.json"))
    }

    /// Selection is deliberately opaque so text can invert on top of it; a
    /// translucent fill leaves dark text on a light row.
    func testSelectionIsOpaque() {
        for dark in [false, true] {
            let fill = Theme.resolved(.selectionFill, dark: dark)
            XCTAssertEqual(fill.alphaComponent, 1, accuracy: 0.001,
                           "a washed-out selection is what made text unreadable")
            XCTAssertEqual(fill.hexString.count, 7, "opaque colours write as #RRGGBB")
        }
    }

    /// Translucent slots still round-trip, for the ones that are meant to be.
    func testTranslucentSlotsSurviveTheTemplateRoundTrip() {
        let tint = Theme.resolved(.rowAlternate, dark: false)
        let text = tint.hexString
        XCTAssertEqual(text.count, 9, "a translucent colour must be written as #RRGGBBAA: \(text)")
        XCTAssertEqual(hex(NSColor(hexString: text)), text)
    }

    /// The whole point of the change: enough contrast to read white on it.
    func testSelectionIsDarkEnoughForWhiteText() {
        for dark in [false, true] {
            let fill = Theme.resolved(.selectionFill, dark: dark).usingColorSpace(.sRGB)!
            // Rec. 601 luma; white text needs a genuinely dark ground.
            let luma = 0.299 * fill.redComponent + 0.587 * fill.greenComponent + 0.114 * fill.blueComponent
            XCTAssertLessThan(luma, 0.5, "white text needs a dark fill behind it")
        }
    }
}
