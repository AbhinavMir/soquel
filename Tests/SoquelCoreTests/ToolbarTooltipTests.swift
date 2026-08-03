import AppKit
import XCTest
@testable import SoquelCore

final class ToolbarTooltipTests: XCTestCase {
    /// The tooltip names the key, so the toolbar teaches the shortcut instead
    /// of replacing it.
    func testATooltipCarriesTheShortcut() throws {
        let hidden = try XCTUnwrap(ToolbarCatalogue.action(id: "hidden"))
        XCTAssertTrue(hidden.tooltip.contains("⇧⌘."), hidden.tooltip)
        XCTAssertTrue(hidden.tooltip.hasPrefix(hidden.currentTitle), hidden.tooltip)
    }

    /// An action with no bound key is just its title, not a title with a
    /// dangling separator after it.
    func testAnUnboundActionIsJustItsTitle() throws {
        let favourite = try XCTUnwrap(ToolbarCatalogue.action(id: "favourite"))
        if ToolbarCatalogue.shortcutDisplay(for: favourite.selector) == nil {
            XCTAssertEqual(favourite.tooltip, favourite.currentTitle)
        }
    }

    /// The tooltip follows the button's state, so a toggle that is on offers to
    /// turn itself off rather than claiming it would turn itself on again.
    func testTheTooltipFollowsTheToggleState() throws {
        let hidden = try XCTUnwrap(ToolbarCatalogue.action(id: "hidden"))
        let was = Prefs.showHiddenFiles
        defer { Prefs.showHiddenFiles = was }

        Prefs.showHiddenFiles = true
        XCTAssertTrue(hidden.tooltip.hasPrefix("Hide Hidden Files"), hidden.tooltip)
        Prefs.showHiddenFiles = false
        XCTAssertTrue(hidden.tooltip.hasPrefix("Show Hidden Files"), hidden.tooltip)
    }

    /// A remapped key shows the new one, not the shipped default.
    func testARemappedKeyIsWhatTheTooltipShows() throws {
        let command = try XCTUnwrap(CommandRegistry.all.first { $0.id == "view.hidden" })
        defer { CommandRegistry.resetShortcut(for: command) }

        CommandRegistry.setShortcut(Shortcut("j", [.command, .control]), for: command)
        let hidden = try XCTUnwrap(ToolbarCatalogue.action(id: "hidden"))
        XCTAssertTrue(hidden.tooltip.contains("⌃⌘J"), hidden.tooltip)
    }
}
