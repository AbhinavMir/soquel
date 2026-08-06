import AppKit
import XCTest
@testable import SoquelCore

final class IconZoomTests: XCTestCase {
    /// A step is proportional, so it feels the same at 32 as at 200 rather
    /// than being a leap at one end and nothing at the other.
    func testAStepIsProportional() {
        XCTAssertEqual(Prefs.zoomedIconSize(from: 72, larger: true), 90)
        XCTAssertEqual(Prefs.zoomedIconSize(from: 72, larger: false), 58)
    }

    func testItStopsAtBothEnds() {
        XCTAssertEqual(Prefs.zoomedIconSize(from: Prefs.maximumIconSize, larger: true),
                       Prefs.maximumIconSize)
        XCTAssertEqual(Prefs.zoomedIconSize(from: Prefs.minimumIconSize, larger: false),
                       Prefs.minimumIconSize)
    }

    /// Zooming out and back in returns to roughly where it started.
    func testItIsReversible() {
        let out = Prefs.zoomedIconSize(from: 100, larger: false)
        let back = Prefs.zoomedIconSize(from: out, larger: true)
        XCTAssertEqual(back, 100, accuracy: 2)
    }

    /// A stored value outside the range cannot make icons invisible or fill
    /// the pane with one.
    func testAStoredSizeIsClamped() {
        let was = Prefs.iconSize
        defer { Prefs.iconSize = was }
        Prefs.iconSize = 5000
        XCTAssertEqual(Prefs.iconSize, Prefs.maximumIconSize)
        Prefs.iconSize = 1
        XCTAssertEqual(Prefs.iconSize, Prefs.minimumIconSize)
    }
}

final class ColumnViewWidthTests: XCTestCase {
    func testTheWidthIsRemembered() {
        let was = ColumnBrowserView.columnWidth
        defer { ColumnBrowserView.columnWidth = was }
        ColumnBrowserView.columnWidth = 300
        XCTAssertEqual(ColumnBrowserView.columnWidth, 300)
    }

    /// Dragging must not be able to collapse a column to nothing, nor stretch
    /// one past the width of any window.
    func testItStopsAtBothEnds() {
        let was = ColumnBrowserView.columnWidth
        defer { ColumnBrowserView.columnWidth = was }
        ColumnBrowserView.columnWidth = 10
        XCTAssertEqual(ColumnBrowserView.columnWidth, ColumnBrowserView.minimumColumnWidth)
        ColumnBrowserView.columnWidth = 5000
        XCTAssertEqual(ColumnBrowserView.columnWidth, ColumnBrowserView.maximumColumnWidth)
    }
}
