import AppKit
import XCTest
@testable import SoquelCore

final class ThemeTests: XCTestCase {
    private func hex(_ color: NSColor?) -> String? { color?.hexString }

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

    func testTemplateContainsEverySlotForBothAppearances() throws {
        var written: [String: [String: String]] = [:]
        let config = ThemeConfig(
            light: Dictionary(uniqueKeysWithValues: ThemeConfig.Slot.allCases.map {
                ($0.rawValue, Theme.resolved($0, dark: false).hexString)
            }),
            dark: Dictionary(uniqueKeysWithValues: ThemeConfig.Slot.allCases.map {
                ($0.rawValue, Theme.resolved($0, dark: true).hexString)
            })
        )
        written["light"] = config.light
        written["dark"] = config.dark

        for slot in ThemeConfig.Slot.allCases {
            XCTAssertNotNil(written["light"]?[slot.rawValue], "\(slot.rawValue) missing from light")
            XCTAssertNotNil(written["dark"]?[slot.rawValue], "\(slot.rawValue) missing from dark")
        }
        // Every written value must parse back, or the template teaches a format
        // the reader cannot use.
        for value in Array(config.light.values) + Array(config.dark.values) {
            XCTAssertNotNil(NSColor(hexString: value), "\(value) is not re-readable")
        }
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
