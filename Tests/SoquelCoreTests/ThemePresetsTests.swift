import AppKit
import XCTest
@testable import SoquelCore

final class ThemePresetsTests: XCTestCase {
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

    func testApplyingAPresetWritesItsColours() {
        let paper = try! XCTUnwrap(ThemePresets.all.first { $0.name == "Paper" })
        ThemePresets.apply(paper)
        XCTAssertEqual(Theme.config.light["accent"], paper.light["accent"])
        XCTAssertEqual(Theme.config.dark["accent"], paper.dark["accent"])
    }

    /// Colours and the background picture are chosen separately. Picking a
    /// palette must not throw away the image behind the file list.
    func testApplyingAPresetKeepsTheBackground() {
        Theme.setBackground(BackgroundConfig(
            imagePath: "/tmp/sakura.png", opacity: 0.32, fit: .fill, includeSidebar: true))
        ThemePresets.apply(ThemePresets.all[1])
        XCTAssertEqual(Theme.config.background?.imagePath, "/tmp/sakura.png")
        XCTAssertEqual(Theme.config.background?.opacity, 0.32)
    }

    /// Which preset is in use is worked out by comparing colours, never stored.
    /// A remembered name is a second source of truth that can disagree with the
    /// file, which is what used to revert hand edits at launch.
    func testTheCurrentPresetIsDerivedFromTheColours() {
        XCTAssertEqual(ThemePresets.current?.name, "Soquel", "no overrides is the shipped set")

        let terminal = ThemePresets.all.first { $0.name == "Terminal" }!
        ThemePresets.apply(terminal)
        XCTAssertEqual(ThemePresets.current?.name, "Terminal")
    }

    func testEditingAColourMeansNoPresetIsInUse() {
        ThemePresets.apply(ThemePresets.all.first { $0.name == "Paper" }!)
        var edited = Theme.config
        edited.light["accent"] = "#123456"
        Theme.apply(edited)
        XCTAssertNil(ThemePresets.current, "an edited palette is your own, not a preset")
    }

    /// Applying a preset and relaunching must give back the same colours. The
    /// launch path reads theme.json and nothing else.
    func testAPresetSurvivesARelaunch() throws {
        ThemePresets.apply(ThemePresets.all.first { $0.name == "Sakura" }!)
        Theme.config = .empty                       // as if freshly launched
        Theme.reload()
        XCTAssertEqual(ThemePresets.current?.name, "Sakura")
    }

    /// A hand edit to theme.json is the truth; nothing re-applies over it.
    func testAHandEditToTheFileSurvivesARelaunch() throws {
        try ThemeConfig.write(ThemeConfig(light: ["accent": "#7B7B00"], dark: [:]))
        Theme.config = .empty
        Theme.reload()
        XCTAssertEqual(Theme.config.light["accent"], "#7B7B00")
    }

    // MARK: - What ships

    func testEveryPresetCoversEverySlotInBothAppearances() {
        for preset in ThemePresets.all where !preset.light.isEmpty {
            for slot in ThemeConfig.Slot.allCases {
                XCTAssertNotNil(preset.light[slot.rawValue], "\(preset.name) light \(slot.rawValue)")
                XCTAssertNotNil(preset.dark[slot.rawValue], "\(preset.name) dark \(slot.rawValue)")
            }
        }
    }

    func testEveryPresetColourParses() {
        for preset in ThemePresets.all {
            for hex in Array(preset.light.values) + Array(preset.dark.values) {
                XCTAssertNotNil(NSColor(hexString: hex), "\(preset.name): \(hex) does not parse")
            }
        }
    }

    func testPresetNamesAreUnique() {
        XCTAssertEqual(Set(ThemePresets.all.map(\.name)).count, ThemePresets.all.count)
    }
}
