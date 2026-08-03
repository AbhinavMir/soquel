import XCTest
@testable import SoquelCore

final class AppearanceLabelTests: XCTestCase {
    /// Nothing in the list should be a word only someone who writes user
    /// interfaces would use.
    func testNoJargonInTheNames() {
        let jargon = ["accent", "chrome", "hairline", "fill", "slot"]
        for slot in ThemeConfig.Slot.allCases {
            let title = AppearanceSettingsView.title(for: slot).lowercased()
            for word in jargon {
                XCTAssertFalse(title.contains(word), "\(slot.rawValue) is titled “\(title)”")
            }
        }
    }

    /// Every slot says where it turns up, in a sentence.
    func testEverySlotIsExplained() {
        for slot in ThemeConfig.Slot.allCases {
            let text = AppearanceSettingsView.explanation(for: slot)
            XCTAssertGreaterThan(text.count, 30, slot.rawValue)
            XCTAssertTrue(text.hasSuffix("."), "\(slot.rawValue): \(text)")
        }
    }

    func testTitlesAreDistinct() {
        let titles = ThemeConfig.Slot.allCases.map { AppearanceSettingsView.title(for: $0) }
        XCTAssertEqual(Set(titles).count, titles.count)
    }
}
