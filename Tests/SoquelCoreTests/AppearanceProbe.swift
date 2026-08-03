import AppKit
import XCTest
@testable import SoquelCore

final class AppearanceProbeTests: XCTestCase {
    /// Exactly what wellChanged does: read the config, put a colour in a slot,
    /// apply it, then read it back.
    func testPickingAColourPersistsAndComesBack() throws {
        var config = Theme.config
        config.light[ThemeConfig.Slot.accent.rawValue] = NSColor.systemOrange.hexString
        Theme.apply(config)

        let stored = Theme.config.light[ThemeConfig.Slot.accent.rawValue]
        XCTAssertEqual(stored, NSColor.systemOrange.hexString, "the slot did not keep the colour")
        XCTAssertEqual(Theme.resolved(.accent, dark: false).hexString, NSColor.systemOrange.hexString)
    }

    /// A near-transparent slot round-trips its alpha rather than losing it.
    func testAlphaSurvivesTheRoundTrip() {
        let faint = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)
        XCTAssertEqual(faint.hexString.count, 9, faint.hexString)
        XCTAssertEqual(NSColor(hexString: faint.hexString)?.alphaComponent ?? -1, 0.10, accuracy: 0.01)
    }
}
