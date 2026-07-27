import XCTest
import AppKit
@testable import SoquelCore

final class KeyboardFirstTests: XCTestCase {
    private func action(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                        pendingG: Bool = false) -> KeyboardFirst.Action? {
        KeyboardFirst.action(forCharacters: characters, modifiers: modifiers, pendingG: pendingG)
    }

    func testMovementKeys() {
        XCTAssertEqual(action("j"), .moveDown)
        XCTAssertEqual(action("k"), .moveUp)
    }

    func testShiftedMovementExtendsTheSelection() {
        XCTAssertEqual(action("J", .shift), .extendDown)
        XCTAssertEqual(action("K", .shift), .extendUp)
    }

    func testNavigationKeys() {
        XCTAssertEqual(action("h"), .goToParent)
        XCTAssertEqual(action("l"), .openSelection)
        XCTAssertEqual(action("H", .shift), .goBack)
        XCTAssertEqual(action("L", .shift), .goForward)
    }

    func testHalfPageNeedsControl() {
        XCTAssertEqual(action("d", .control), .halfPageDown)
        XCTAssertEqual(action("u", .control), .halfPageUp)
        XCTAssertNil(action("d"))
        XCTAssertNil(action("u"))
    }

    func testCapitalGGoesToTheEnd() {
        XCTAssertEqual(action("G", .shift), .moveToBottom)
    }

    /// A single g does nothing until the second one arrives.
    func testDoubleGGoesToTheTop() {
        XCTAssertEqual(action("g"), .awaitingSecondG)
        XCTAssertEqual(action("g", pendingG: true), .moveToTop)
    }

    func testAnUnrelatedKeyAfterGIsHandledOnItsOwn() {
        XCTAssertEqual(action("j", pendingG: true), .moveDown)
    }

    /// Command and Option belong to the menu shortcuts; the preset must not
    /// claim ⌘J or ⌥L out from under them.
    func testCommandAndOptionAreNotClaimed() {
        XCTAssertNil(action("j", .command))
        XCTAssertNil(action("l", .option))
        XCTAssertNil(action("k", [.command, .shift]))
    }

    func testUnmappedLettersFallThroughToTypeSelect() {
        XCTAssertNil(action("a"))
        XCTAssertNil(action("z"))
        XCTAssertNil(action("1"))
    }

    func testSlashStartsTheFilter() {
        XCTAssertEqual(action("/"), .beginFilter)
    }

    func testCapsLockDoesNotChangeTheMeaning() {
        XCTAssertEqual(action("j", .capsLock), .moveDown)
    }

    func testEveryBindingIsDocumented() {
        // The settings window and the docs both read this list; a binding that
        // is not in it is undiscoverable.
        let documented = KeyboardFirst.bindings.map(\.keys).joined(separator: " ")
        for key in ["j", "k", "g g", "G", "h", "l", "/"] {
            XCTAssertTrue(documented.contains(key), "\(key) is not documented")
        }
    }
}
