import XCTest
import AppKit
@testable import SoquelCore

/// Shortcuts macOS itself claims. Binding one of these means the menu item
/// never fires — ⌃⌘M was bound to the disk map and minimised the window
/// instead, which the duplicate-shortcut test could not catch because the
/// clash is with the system, not with another command here.
final class SystemShortcutTests: XCTestCase {
    /// key → the modifier sets macOS reserves for it.
    private let reserved: [String: [NSEvent.ModifierFlags]] = [
        // Minimize, Minimize All, and the window-management variants around them.
        "m": [[.command], [.command, .option], [.command, .control]],
        // Hide and Hide Others.
        "h": [[.command], [.command, .option]],
        "q": [[.command]],
        // Spotlight and the character palette.
        " ": [[.command], [.command, .option], [.command, .control]],
    ]

    private func allShortcuts() -> [(id: String, shortcut: Shortcut)] {
        CommandRegistry.sections.flatMap(\.entries).compactMap { entry in
            guard case .command(let command) = entry,
                  let shortcut = CommandRegistry.shortcut(for: command)
            else { return nil }
            return (command.id, shortcut)
        }
    }

    func testNoCommandClaimsASystemShortcut() {
        for (id, shortcut) in allShortcuts() {
            guard let claimed = reserved[shortcut.key.lowercased()] else { continue }
            for modifiers in claimed {
                XCTAssertNotEqual(
                    shortcut.flags, modifiers,
                    "\(id) is bound to a shortcut macOS reserves; it will not fire"
                )
            }
        }
    }

    /// The one that actually bit: the disk map must not be on the M key at all.
    func testTheDiskMapIsNotOnTheMinimiseKey() {
        let diskMap = allShortcuts().first { $0.id == "view.diskMap" }
        XCTAssertNotNil(diskMap, "the disk map should have a shortcut")
        XCTAssertNotEqual(diskMap?.shortcut.key.lowercased(), "m")
    }

    func testEveryShortcutUsesAModifier() {
        // A bare letter as a menu key equivalent is swallowed in every text
        // field in the application.
        for (id, shortcut) in allShortcuts() where !shortcut.key.isEmpty {
            let plain = shortcut.flags.intersection([.command, .control, .option]).isEmpty
            XCTAssertFalse(plain, "\(id) has no command, control or option modifier")
        }
    }
}
