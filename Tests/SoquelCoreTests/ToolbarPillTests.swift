import XCTest
import AppKit
@testable import SoquelCore

/// The view-mode pill: the fill must sit under the segment that is actually on.
final class ToolbarPillTests: XCTestCase {
    private var original: ViewMode!

    override func setUp() {
        super.setUp()
        original = Prefs.viewMode
    }

    override func tearDown() {
        Prefs.viewMode = original
        super.tearDown()
    }

    private var viewModeActions: [ToolbarAction] {
        ["listView", "iconView", "columnView"].compactMap { ToolbarCatalogue.action(id: $0) }
    }

    private func pill(width: CGFloat = 90) -> ToolbarPillView {
        let pill = ToolbarPillView(actions: viewModeActions)
        pill.frame = NSRect(x: 0, y: 0, width: width, height: ToolbarPillView.height)
        pill.layoutSubtreeIfNeeded()
        pill.layout()
        return pill
    }

    func testTheCatalogueOrderIsListIconColumn() {
        XCTAssertEqual(viewModeActions.map(\.id), ["listView", "iconView", "columnView"])
    }

    func testEachViewModeLightsItsOwnSegment() {
        let expected: [(ViewMode, Int)] = [(.list, 0), (.icon, 1), (.column, 2)]
        for (mode, index) in expected {
            Prefs.viewMode = mode
            XCTAssertEqual(
                ToolbarPillView.selectedIndex(in: viewModeActions), index,
                "\(mode) should light segment \(index)"
            )
        }
    }

    func testExactlyOneSegmentIsEverOn() {
        for mode in ViewMode.allCases {
            Prefs.viewMode = mode
            let on = viewModeActions.filter { $0.isOn?() == true }
            XCTAssertEqual(on.count, 1, "\(mode) lit \(on.count) segments")
        }
    }

    /// The fill has to land on the segment, not merely somewhere in the pill.
    func testTheFillSitsOnTheSelectedSegment() {
        for (mode, index) in [(ViewMode.list, 0), (.icon, 1), (.column, 2)] {
            Prefs.viewMode = mode
            let view = pill()
            let state = view.selectionState
            XCTAssertFalse(state.hidden, "\(mode): the fill should be showing")
            XCTAssertEqual(state.index, index)
            XCTAssertEqual(
                state.frame, view.segmentFrames[index],
                "\(mode): the fill is on segment \(view.segmentFrames.firstIndex(of: state.frame) ?? -1)"
            )
        }
    }

    /// Segments divide whatever width the pill has, rather than each taking a
    /// fixed 30pt — at a fixed width the later segments fall outside a pill
    /// that is anything other than exactly three times 30.
    func testSegmentsTileThePillExactly() {
        Prefs.viewMode = .column
        let view = pill()
        let frames = view.segmentFrames
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.first?.minX, 0)
        XCTAssertEqual(frames.last?.maxX ?? 0, view.bounds.width, accuracy: 0.001)
        XCTAssertEqual(view.selectionState.frame, frames[2])
    }

    /// The pill asks for exactly three segments' worth of width, so it is never
    /// squeezed into showing two and a half.
    func testThePillHoldsItsWidth() {
        let view = pill()
        XCTAssertEqual(
            view.bounds.width,
            ToolbarPillView.segmentWidth * CGFloat(viewModeActions.count),
            accuracy: 0.001
        )
    }

    func testSegmentsDoNotOverlap() {
        let frames = pill().segmentFrames
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
        }
    }

    func testTheFillIsBehindTheIcons() {
        // Drawn first means drawn underneath; the other way round hides them.
        let view = pill()
        XCTAssertEqual(view.subviews.count, 4)
        XCTAssertFalse(view.subviews[0] is NSButton)
    }

    func testAGroupWithNothingOnShowsNoFill() {
        // A pill whose actions are all off must not keep a stale fill.
        let off = [ToolbarAction("a", "A", "circle", #selector(NSView.layout), isOn: { false }, group: "g")]
        let view = ToolbarPillView(actions: off)
        view.frame = NSRect(x: 0, y: 0, width: 30, height: ToolbarPillView.height)
        view.layout()
        XCTAssertTrue(view.selectionState.hidden)
    }
}
