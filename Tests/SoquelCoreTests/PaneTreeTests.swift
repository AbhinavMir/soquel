import XCTest
@testable import SoquelCore

final class PaneTreeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let s1 = UUID(), s2 = UUID(), s3 = UUID()

    func testASinglePaneIsALeaf() {
        let tree = PaneNode.leaf(a)
        XCTAssertEqual(tree.leaves, [a])
        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertEqual(tree.depth, 0)
    }

    func testSplittingALeafMakesASplitOfTwo() {
        let tree = PaneNode.leaf(a).splitting(a, vertical: true, into: b, splitID: s1)
        XCTAssertEqual(tree, .split(id: s1, vertical: true, children: [.leaf(a), .leaf(b)]))
        XCTAssertEqual(tree.leaves, [a, b])
    }

    /// Nesting a vertical split inside a vertical split adds a divider and
    /// changes nothing, so the new pane joins the existing row instead.
    func testSplittingTheSameDirectionAddsASibling() {
        let tree = PaneNode.leaf(a)
            .splitting(a, vertical: true, into: b, splitID: s1)
            .splitting(b, vertical: true, into: c, splitID: s2)

        XCTAssertEqual(tree, .split(id: s1, vertical: true, children: [.leaf(a), .leaf(b), .leaf(c)]))
        XCTAssertEqual(tree.depth, 1)
    }

    func testASiblingIsInsertedRightAfterTheSplitPane() {
        let tree = PaneNode.leaf(a)
            .splitting(a, vertical: true, into: b, splitID: s1)
            .splitting(a, vertical: true, into: c, splitID: s2)
        XCTAssertEqual(tree.leaves, [a, c, b])
    }

    /// The whole point: splitting one pane the other way leaves the rest alone.
    func testSplittingTheOtherDirectionNests() {
        let tree = PaneNode.leaf(a)
            .splitting(a, vertical: true, into: b, splitID: s1)
            .splitting(b, vertical: false, into: c, splitID: s2)

        XCTAssertEqual(tree, .split(id: s1, vertical: true, children: [
            .leaf(a),
            .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ]))
        XCTAssertEqual(tree.depth, 2)
        XCTAssertEqual(tree.leaves, [a, b, c])
    }

    func testATwoByTwoGrid() {
        let tree = PaneNode.leaf(a)
            .splitting(a, vertical: true, into: b, splitID: s1)
            .splitting(a, vertical: false, into: c, splitID: s2)
            .splitting(b, vertical: false, into: d, splitID: s3)

        XCTAssertEqual(tree.leafCount, 4)
        XCTAssertEqual(tree.depth, 2)
        XCTAssertEqual(tree.leaves, [a, c, b, d])
    }

    func testSplittingAnUnknownPaneChangesNothing() {
        let tree = PaneNode.leaf(a).splitting(a, vertical: true, into: b, splitID: s1)
        XCTAssertEqual(tree.splitting(UUID(), vertical: false, into: c, splitID: s2), tree)
    }

    // MARK: - Removing

    func testRemovingTheOnlyPaneEmptiesTheTree() {
        XCTAssertNil(PaneNode.leaf(a).removing(a))
    }

    /// A split holding one child is a divider with nothing on one side of it.
    func testASplitOfTwoCollapsesWhenOneGoes() {
        let tree = PaneNode.leaf(a).splitting(a, vertical: true, into: b, splitID: s1)
        XCTAssertEqual(tree.removing(b), .leaf(a))
        XCTAssertEqual(tree.removing(a), .leaf(b))
    }

    func testASplitOfThreeKeepsItsShape() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(tree.removing(b), .split(id: s1, vertical: true, children: [.leaf(a), .leaf(c)]))
    }

    func testRemovingFromANestedSplitCollapsesOnlyThatLevel() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [
            .leaf(a),
            .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ])
        XCTAssertEqual(tree.removing(c), .split(id: s1, vertical: true, children: [.leaf(a), .leaf(b)]))
        XCTAssertEqual(tree.removing(c)?.depth, 1)
    }

    func testRemovingAnUnknownPaneChangesNothing() {
        let tree = PaneNode.leaf(a).splitting(a, vertical: true, into: b, splitID: s1)
        XCTAssertEqual(tree.removing(UUID()), tree)
    }

    func testRemovingEverythingOneAtATime() {
        var tree: PaneNode? = PaneNode.leaf(a)
            .splitting(a, vertical: true, into: b, splitID: s1)
            .splitting(b, vertical: false, into: c, splitID: s2)
        tree = tree?.removing(b)
        XCTAssertEqual(tree?.leaves, [a, c])
        tree = tree?.removing(c)
        XCTAssertEqual(tree, .leaf(a))
        tree = tree?.removing(a)
        XCTAssertNil(tree)
    }

    // MARK: - Order and focus

    func testNextAndPreviousWrapAround() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(tree.leaf(after: a), b)
        XCTAssertEqual(tree.leaf(after: c), a)
        XCTAssertEqual(tree.leaf(before: a), c)
        XCTAssertEqual(tree.leaf(before: b), a)
    }

    func testOrderIsLeftToRightThenTopToBottom() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [
            .split(id: s2, vertical: false, children: [.leaf(a), .leaf(b)]),
            .leaf(c),
        ])
        XCTAssertEqual(tree.leaves, [a, b, c])
    }

    func testContains() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [
            .leaf(a), .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ])
        XCTAssertTrue(tree.contains(c))
        XCTAssertFalse(tree.contains(d))
    }

    // MARK: - Rotating

    func testRotatingFlipsOnlyTheContainingSplit() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [
            .leaf(a),
            .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ])
        let rotated = tree.rotatingContainer(of: b)
        XCTAssertEqual(rotated, .split(id: s1, vertical: true, children: [
            .leaf(a),
            .split(id: s2, vertical: true, children: [.leaf(b), .leaf(c)]),
        ]))
    }

    func testRotatingASinglePaneDoesNothing() {
        XCTAssertEqual(PaneNode.leaf(a).rotatingContainer(of: a), .leaf(a))
    }

    func testSplitIDsAreCollected() {
        let tree = PaneNode.split(id: s1, vertical: true, children: [
            .leaf(a), .split(id: s2, vertical: false, children: [.leaf(b), .leaf(c)]),
        ])
        XCTAssertEqual(Set(tree.splitIDs), [s1, s2])
    }
}
