import XCTest
@testable import SoquelCore

/// Saving and reopening a nested pane arrangement.
final class WorkspaceLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private let s1 = UUID(), s2 = UUID()

    /// One pane left, two stacked right — the case the flat format could not
    /// express.
    private var nestedTree: PaneNode {
        .split(id: s1, vertical: true, children: [
            .leaf(a),
            .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ])
    }

    func testATreeSurvivesSavingAndReopening() throws {
        let order = [a, b, c]
        let saved = try XCTUnwrap(nestedTree.indexed(by: order))

        let rebuilt = try XCTUnwrap(PaneNode.rebuilt(
            from: saved, paneIDs: [0: a, 1: b, 2: c]
        ))
        XCTAssertEqual(rebuilt.leaves, [a, b, c])
        XCTAssertEqual(rebuilt.depth, 2)
    }

    func testIndicesFollowReadingOrder() throws {
        let saved = try XCTUnwrap(nestedTree.indexed(by: [a, b, c]))
        XCTAssertEqual(saved.indices, [0, 1, 2])
    }

    func testASinglePaneNeedsNoSplit() throws {
        let saved = try XCTUnwrap(PaneNode.leaf(a).indexed(by: [a]))
        XCTAssertEqual(saved, .pane(0))
    }

    /// Round-trips through JSON, because that is how it is actually stored.
    func testTheLayoutIsCodable() throws {
        let saved = try XCTUnwrap(nestedTree.indexed(by: [a, b, c]))
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(Workspace.LayoutNode.self, from: data)
        XCTAssertEqual(decoded, saved)
    }

    // MARK: - Missing folders

    private func workspace(layout: Workspace.LayoutNode?, panes: [[String]]) -> Workspace {
        Workspace(name: "test", panes: panes, activeTabs: panes.map { _ in 0 },
                  isVerticalSplit: true, layout: layout)
    }

    func testAWorkspaceWithNoLayoutReopensFlat() {
        let saved = workspace(layout: nil, panes: [["/tmp"], ["/usr"]])
        XCTAssertNil(saved.survivingLayout())
    }

    /// A pane whose folder has gone leaves a gap the arrangement has to close,
    /// and the remaining panes have to be renumbered around it.
    func testADroppedPaneIsRemovedAndTheRestRenumbered() throws {
        let layout = Workspace.LayoutNode.split(vertical: true, children: [
            .pane(0),
            .split(vertical: false, children: [.pane(1), .pane(2)]),
        ])
        let saved = workspace(
            layout: layout,
            panes: [["/tmp"], ["/nonexistent-\(UUID().uuidString)"], ["/usr"]]
        )

        let surviving = try XCTUnwrap(saved.survivingLayout())
        // /tmp and /usr survive and are renumbered 0 and 1; the split that held
        // the missing pane collapses to its one remaining child.
        XCTAssertEqual(surviving.indices, [0, 1])
        XCTAssertEqual(surviving, .split(vertical: true, children: [.pane(0), .pane(1)]))
    }

    func testAWholeSideDisappearing() throws {
        let layout = Workspace.LayoutNode.split(vertical: true, children: [
            .pane(0),
            .split(vertical: false, children: [.pane(1), .pane(2)]),
        ])
        let missing = "/nonexistent-\(UUID().uuidString)"
        let saved = workspace(layout: layout, panes: [["/tmp"], [missing], [missing]])

        let surviving = try XCTUnwrap(saved.survivingLayout())
        XCTAssertEqual(surviving, .pane(0))
    }

    func testEverythingMissingLeavesNoLayout() {
        let missing = "/nonexistent-\(UUID().uuidString)"
        let layout = Workspace.LayoutNode.split(vertical: true, children: [.pane(0), .pane(1)])
        let saved = workspace(layout: layout, panes: [[missing], [missing]])
        XCTAssertNil(saved.survivingLayout())
    }

    func testSurvivingPanesKeepTheirOriginalPositions() {
        let missing = "/nonexistent-\(UUID().uuidString)"
        let saved = workspace(layout: nil, panes: [[missing], ["/tmp"], ["/usr"]])
        XCTAssertEqual(saved.survivingPanesWithIndices().map(\.index), [1, 2])
    }

    /// Rebuilding must not invent panes for indices that were never created.
    func testRebuildingSkipsPanesThatWereNotCreated() throws {
        let layout = Workspace.LayoutNode.split(vertical: true, children: [.pane(0), .pane(1)])
        let rebuilt = try XCTUnwrap(PaneNode.rebuilt(from: layout, paneIDs: [0: a]))
        XCTAssertEqual(rebuilt, .leaf(a))
    }

    func testRebuildingNothingGivesNothing() {
        let layout = Workspace.LayoutNode.pane(5)
        XCTAssertNil(PaneNode.rebuilt(from: layout, paneIDs: [0: a]))
    }
}
