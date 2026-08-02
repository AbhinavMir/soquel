import XCTest
import AppKit
@testable import SoquelCore

/// Clicking the path bar swaps the breadcrumbs for a typable field.
///
/// It used to hide the breadcrumbs whatever happened: the result of
/// `makeFirstResponder` was discarded and the window it was sent to was
/// optional-chained, so a pane with no window, or one whose current responder
/// refused to resign, was left showing a field it could not edit and no path
/// bar at all. The move now has to succeed before the swap stands.
final class SweepPaneTests: XCTestCase {
    private typealias Pane = PaneViewController

    // MARK: - Did the field actually take focus

    func testAMoveThatSucceededCountsAsFocus() {
        XCTAssertTrue(Pane.pathFieldTookFocus(true))
    }

    /// A responder that will not resign — an inline rename holding a name
    /// AppKit rejects — leaves the field unfocused.
    func testARefusedMoveIsNotFocus() {
        XCTAssertFalse(Pane.pathFieldTookFocus(false))
    }

    /// nil is what the optional chain through `view.window` produces when the
    /// pane is in no window, which is not focus either. This is the case the
    /// old code could not distinguish, since it read no result at all.
    func testNoWindowIsNotFocus() {
        XCTAssertFalse(Pane.pathFieldTookFocus(nil))
    }

    // MARK: - What the second half of the guard is for

    /// Focus is only worth acting on once the cell has handed back a field
    /// editor: that is what carries the selection and what Escape is delivered
    /// through. A field outside a window has none, so the guard has to fire
    /// rather than select into thin air.
    func testAFieldOutsideAWindowHasNoEditor() {
        let field = NSTextField()
        XCTAssertNil(field.currentEditor())
    }
}


/// Closing a tab from its own button, rather than always the active one.
final class TabCloseIndexTests: XCTestCase {
    private func after(closed: Int, active: Int, remaining: Int) -> Int {
        PaneViewController.activeIndexAfterClosing(closed, wasActive: active, remaining: remaining)
    }

    /// Closing a tab to the left shifts the active one down, so the pane keeps
    /// showing the folder it was showing.
    func testClosingATabToTheLeftKeepsTheSameTabInFront() {
        XCTAssertEqual(after(closed: 0, active: 2, remaining: 3), 1)
        XCTAssertEqual(after(closed: 1, active: 3, remaining: 3), 2)
    }

    /// Closing a tab to the right leaves the active index alone.
    func testClosingATabToTheRightLeavesTheActiveOneWhereItIs() {
        XCTAssertEqual(after(closed: 3, active: 1, remaining: 3), 1)
        XCTAssertEqual(after(closed: 2, active: 0, remaining: 3), 0)
    }

    /// Closing the active tab falls to whatever slid into its place.
    func testClosingTheActiveTabFallsToItsNeighbour() {
        XCTAssertEqual(after(closed: 1, active: 1, remaining: 3), 1)
        // The last tab has nothing to its right, so it falls back one.
        XCTAssertEqual(after(closed: 2, active: 2, remaining: 2), 1)
    }

    /// The index can never point past the end, whatever it is handed.
    func testTheResultIsAlwaysAValidIndex() {
        for closed in 0..<5 {
            for active in 0..<5 {
                for remaining in 1..<5 {
                    let index = after(closed: closed, active: active, remaining: remaining)
                    XCTAssertTrue((0..<remaining).contains(index),
                                  "closed=\(closed) active=\(active) remaining=\(remaining) gave \(index)")
                }
            }
        }
    }
}
