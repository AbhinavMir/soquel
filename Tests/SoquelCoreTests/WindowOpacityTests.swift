import AppKit
import XCTest
@testable import SoquelCore

final class WindowOpacityTests: XCTestCase {
    /// Never set means solid, so an existing theme.json does not suddenly go
    /// see-through when this ships.
    func testAnUnsetOpacityIsSolid() {
        XCTAssertEqual(ThemeConfig(light: [:], dark: [:]).effectiveWindowOpacity, 1)
    }

    /// A window you cannot see is a window you cannot click back to.
    func testItCannotBeMadeInvisible() {
        let config = ThemeConfig(light: [:], dark: [:], background: nil, windowOpacity: 0)
        XCTAssertEqual(config.effectiveWindowOpacity, CGFloat(ThemeConfig.minimumWindowOpacity))
    }

    func testAboveOneIsClamped() {
        let config = ThemeConfig(light: [:], dark: [:], background: nil, windowOpacity: 4)
        XCTAssertEqual(config.effectiveWindowOpacity, 1)
    }

    func testAValueInRangeIsKept() {
        let config = ThemeConfig(light: [:], dark: [:], background: nil, windowOpacity: 0.8)
        XCTAssertEqual(config.effectiveWindowOpacity, 0.8, accuracy: 0.0001)
    }

    /// A file written before this existed still decodes.
    func testAFileWithoutTheKeyStillDecodes() throws {
        let json = Data(#"{"light":{},"dark":{}}"#.utf8)
        let config = try JSONDecoder().decode(ThemeConfig.self, from: json)
        XCTAssertNil(config.windowOpacity)
        XCTAssertEqual(config.effectiveWindowOpacity, 1)
    }
}

final class RetroThemeTests: XCTestCase {
    private func preset(_ name: String) throws -> ThemePreset {
        try XCTUnwrap(ThemePresets.all.first { $0.name == name })
    }

    func testTheRetroThemesAreThere() throws {
        for name in ["Windows 95", "Platinum"] {
            _ = try preset(name)
        }
    }

    /// The Windows 95 greys and navy are the real values, not an impression.
    func testWindows95UsesTheActualSystemColours() throws {
        let win95 = try preset("Windows 95")
        XCTAssertEqual(win95.light["chrome"], "#C0C0C0")
        XCTAssertEqual(win95.light["selectionFill"], "#000080")
    }

    /// Every preset fills every slot, or applying one leaves a colour behind
    /// from whatever was set before.
    func testEveryPresetCoversEverySlot() {
        for preset in ThemePresets.all where !preset.light.isEmpty {
            for slot in ThemeConfig.Slot.allCases {
                XCTAssertNotNil(preset.light[slot.rawValue], "\(preset.name) light \(slot.rawValue)")
                XCTAssertNotNil(preset.dark[slot.rawValue], "\(preset.name) dark \(slot.rawValue)")
            }
        }
    }

    /// Every hex actually parses.
    func testEveryColourParses() {
        for preset in ThemePresets.all {
            for (key, hex) in preset.light.merging(preset.dark, uniquingKeysWith: { a, _ in a }) {
                XCTAssertNotNil(NSColor(hexString: hex), "\(preset.name) \(key) = \(hex)")
            }
        }
    }

    func testNamesAreDistinct() {
        let names = ThemePresets.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
