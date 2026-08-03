import AppKit
import XCTest
@testable import SoquelCore

final class ChromeStyleTests: XCTestCase {
    /// An existing theme.json has no style key and must stay rounded.
    func testTheDefaultIsRounded() throws {
        XCTAssertEqual(ThemeConfig(light: [:], dark: [:]).effectiveStyle, .rounded)
        let old = Data(#"{"light":{},"dark":{}}"#.utf8)
        let config = try JSONDecoder().decode(ThemeConfig.self, from: old)
        XCTAssertNil(config.style)
        XCTAssertEqual(config.effectiveStyle, .rounded)
    }

    /// Square corners and a full-width selection are what carry the look.
    func testBevelledIsSquareAndFullWidth() {
        XCTAssertEqual(ChromeStyle.bevelled.cornerRadius, 0)
        XCTAssertEqual(ChromeStyle.bevelled.selectionInset, 0)
        XCTAssertGreaterThan(ChromeStyle.rounded.cornerRadius, 0)
        XCTAssertGreaterThan(ChromeStyle.rounded.selectionInset, 0)
    }

    /// Windows 95 and Platinum are bevelled; the rest are not.
    func testOnlyTheRetroPresetsAreBevelled() throws {
        for preset in ThemePresets.all {
            let expected: ChromeStyle = ["Windows 95", "Platinum"].contains(preset.name)
                ? .bevelled : .rounded
            XCTAssertEqual(preset.style, expected, preset.name)
        }
    }

    /// Applying a preset carries the style, or the grey arrives without the
    /// square corners that make it Windows 95 rather than grey.
    func testApplyingAPresetCarriesItsStyle() throws {
        let win95 = try XCTUnwrap(ThemePresets.all.first { $0.name == "Windows 95" })
        ThemePresets.apply(win95)
        XCTAssertEqual(Theme.style, .bevelled)
        XCTAssertEqual(ThemePresets.current?.name, "Windows 95")

        let soquel = try XCTUnwrap(ThemePresets.all.first { $0.name == "Soquel" })
        ThemePresets.apply(soquel)
        XCTAssertEqual(Theme.style, .rounded)
    }

    /// Two presets sharing colours but not edges are not the same preset.
    func testTheCurrentPresetAccountsForTheEdges() throws {
        let win95 = try XCTUnwrap(ThemePresets.all.first { $0.name == "Windows 95" })
        ThemePresets.apply(win95)
        var config = Theme.config
        config.style = .rounded
        Theme.apply(config)
        XCTAssertNil(ThemePresets.current, "the edges no longer match, so no preset does")
    }

    func testStyleSurvivesTheRoundTrip() throws {
        let config = ThemeConfig(light: [:], dark: [:], style: .bevelled)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ThemeConfig.self, from: data).style, .bevelled)
    }
}
