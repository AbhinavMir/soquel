import XCTest
import AppKit
@testable import SoquelCore

/// Hiding the sidebar or the inspector has to hand their width to the panes.
///
/// It used not to: the split delegate pinned both columns against
/// `adjustSubviews`, the divider constraints held them off their own edge, and
/// the default positions skipped divider 1 whenever the inspector was off. The
/// column went blank and the divider stayed put.
final class SweepMainwindowTests: XCTestCase {
    private typealias Window = MainWindowController
    private let total: CGFloat = 1080

    /// What `setPosition(_:ofDividerAt:)` is left with once the delegate's
    /// minimum and maximum have been applied.
    private func clamped(_ position: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(position, lower), upper)
    }

    // MARK: - Default divider positions

    func testBothColumnsShownKeepTheirDefaultWidths() {
        let positions = Window.outerDividerPositions(
            total: total, sidebarShown: true, inspectorShown: true
        )
        XCTAssertEqual(positions.sidebar, Window.defaultSidebarWidth)
        XCTAssertEqual(positions.inspector, total - Window.defaultInspectorWidth)
    }

    /// The inspector's 280pt goes to the panes rather than staying reserved.
    func testHidingTheInspectorPutsItsDividerOnTheTrailingEdge() {
        let positions = Window.outerDividerPositions(
            total: total, sidebarShown: true, inspectorShown: false
        )
        XCTAssertEqual(positions.inspector, total)
        XCTAssertEqual(positions.sidebar, Window.defaultSidebarWidth)
    }

    func testHidingTheSidebarPutsItsDividerOnTheLeadingEdge() {
        let positions = Window.outerDividerPositions(
            total: total, sidebarShown: false, inspectorShown: true
        )
        XCTAssertEqual(positions.sidebar, 0)
        XCTAssertEqual(positions.inspector, total - Window.defaultInspectorWidth)
    }

    func testHidingBothLeavesTheWholeWidthToThePanes() {
        let positions = Window.outerDividerPositions(
            total: total, sidebarShown: false, inspectorShown: false
        )
        XCTAssertEqual(positions.sidebar, 0)
        XCTAssertEqual(positions.inspector - positions.sidebar, total)
    }

    /// The panes get everything the two columns are not using, whichever
    /// combination is on show.
    func testThePanesGetEveryPointTheColumnsDoNotUse() {
        for sidebarShown in [true, false] {
            for inspectorShown in [true, false] {
                let positions = Window.outerDividerPositions(
                    total: total, sidebarShown: sidebarShown, inspectorShown: inspectorShown
                )
                let sidebarWidth = sidebarShown ? Window.defaultSidebarWidth : 0
                let inspectorWidth = inspectorShown ? Window.defaultInspectorWidth : 0
                XCTAssertEqual(
                    positions.inspector - positions.sidebar,
                    total - sidebarWidth - inspectorWidth,
                    "sidebar \(sidebarShown), inspector \(inspectorShown)"
                )
            }
        }
    }

    // MARK: - The constraints must not defeat those positions

    /// The 140pt floor used to apply to a hidden sidebar too, so asking for 0
    /// was clamped back to 140 and left a blank column.
    func testAHiddenSidebarHasNoWidthFloor() {
        XCTAssertEqual(Window.outerMinimumSidebarCoordinate(sidebarShown: true),
                       Window.minimumSidebarWidth)
        XCTAssertEqual(Window.outerMinimumSidebarCoordinate(sidebarShown: false), 0)

        let target = Window.outerDividerPositions(
            total: total, sidebarShown: false, inspectorShown: true
        ).sidebar
        let reached = clamped(
            target,
            min: Window.outerMinimumSidebarCoordinate(sidebarShown: false),
            // Divider 0's ceiling is unchanged; it never stood in the way.
            max: Swift.min(Window.maximumSidebarWidth,
                           Swift.max(Window.minimumSidebarWidth, total - Window.minimumPaneWidth))
        )
        XCTAssertEqual(reached, 0)
    }

    /// The 220pt inspector minimum used to apply while it was hidden, which
    /// held divider 1 that far from the trailing edge.
    func testAHiddenInspectorMayReachTheTrailingEdge() {
        XCTAssertEqual(
            Window.outerMaximumInspectorCoordinate(proposedMax: total, inspectorShown: true),
            total - Window.minimumInspectorWidth
        )
        XCTAssertEqual(
            Window.outerMaximumInspectorCoordinate(proposedMax: total, inspectorShown: false),
            total
        )

        let target = Window.outerDividerPositions(
            total: total, sidebarShown: true, inspectorShown: false
        ).inspector
        let reached = clamped(
            target,
            min: Window.defaultSidebarWidth + Window.minimumPaneWidth,
            max: Window.outerMaximumInspectorCoordinate(proposedMax: total, inspectorShown: false)
        )
        XCTAssertEqual(reached, total)
        XCTAssertNotEqual(reached, total - Window.minimumInspectorWidth,
                          "the old ceiling reserved 220pt of blank column")
    }

    /// A shown inspector still keeps its minimum width when the divider is
    /// dragged past it.
    func testAShownInspectorStillKeepsItsMinimumWidth() {
        let reached = clamped(
            total,
            min: Window.defaultSidebarWidth + Window.minimumPaneWidth,
            max: Window.outerMaximumInspectorCoordinate(proposedMax: total, inspectorShown: true)
        )
        XCTAssertEqual(total - reached, Window.minimumInspectorWidth)
    }

    // MARK: - adjustSubviews

    /// Pinning the width of a column that is on show is what keeps a window
    /// resize in the panes.
    func testShownColumnsKeepTheirWidthWhenTheWindowResizes() {
        XCTAssertFalse(Window.outerColumnResizes(isFixedColumn: true, isHidden: false))
    }

    /// A hidden column must be resizable, or `adjustSubviews` leaves its old
    /// width in place and the divider never moves.
    func testHiddenColumnsAreResizable() {
        XCTAssertTrue(Window.outerColumnResizes(isFixedColumn: true, isHidden: true))
    }

    func testThePanesAlwaysAbsorbTheChange() {
        XCTAssertTrue(Window.outerColumnResizes(isFixedColumn: false, isHidden: false))
        XCTAssertTrue(Window.outerColumnResizes(isFixedColumn: false, isHidden: true))
    }
}
