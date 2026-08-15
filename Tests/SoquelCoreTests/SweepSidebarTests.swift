import AppKit
import XCTest
@testable import SoquelCore

/// Revealing the focused pane's folder in the tree.
///
/// The walk used to keep the last ancestor it found and select that when the
/// chain ran out early, which dragged the pane back up out of any folder the
/// tree cannot show.
final class SweepSidebarRevealTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/soquel-reveal", isDirectory: true)

    private func folder(_ url: URL, children: [SidebarNode] = [], loaded: Bool = true) -> SidebarNode {
        let node = SidebarNode(.treeFolder(url), children: children)
        node.childrenLoaded = loaded
        return node
    }

    private func child(_ parent: URL, _ name: String) -> URL {
        parent.appendingPathComponent(name, isDirectory: true)
    }

    /// The tree as the sidebar holds it: "/" at the top, then the levels down
    /// to `base/home`, whose children are given.
    private func roots(homeChildren: [SidebarNode], homeLoaded: Bool = true) -> [SidebarNode] {
        let home = folder(child(base, "home"), children: homeChildren, loaded: homeLoaded)
        let top = folder(base, children: [home])
        return [folder(URL(fileURLWithPath: "/", isDirectory: true), children: [top])]
    }

    func testTheWalkReachesTheFolderWhenEveryLevelIsThere() {
        let documents = child(child(base, "home"), "Documents")
        let level = roots(homeChildren: [folder(documents)])

        let walk = SidebarViewController.revealWalk(chain: FolderTree.chain(to: documents), from: level)

        XCTAssertEqual(walk.target?.url, documents)
        XCTAssertNil(walk.pending)
        XCTAssertEqual(walk.open.map(\.title), ["/", "soquel-reveal", "home", "Documents"])
    }

    /// The ~/Library case: hidden files are off, so FolderTree left it out of
    /// the home node's children and the tree has no row for it. Selecting the
    /// home row instead told the pane to navigate to home, so the pane snapped
    /// straight back out of the folder the user had just entered.
    func testAFolderTheTreeCannotShowIsNotStandingInForItsParent() {
        let library = child(child(base, "home"), "Library")
        let level = roots(homeChildren: [folder(child(child(base, "home"), "Documents"))])

        let walk = SidebarViewController.revealWalk(chain: FolderTree.chain(to: library), from: level)

        XCTAssertNil(walk.target, "no row for this folder means nothing is selected")
        XCTAssertNil(walk.pending)
        XCTAssertEqual(walk.open.map(\.title), ["/", "soquel-reveal", "home"],
                       "the levels that do exist are still opened")
    }

    /// A folder made after its parent was expanded is missing from that
    /// parent's cached children, and childrenLoaded is never invalidated, so
    /// everything below it is unreachable too.
    func testAMissingLevelStopsTheWalkRatherThanSelectingAboveIt() {
        let home = child(base, "home")
        let deep = child(child(home, "made-later"), "inside")
        let level = roots(homeChildren: [])

        let walk = SidebarViewController.revealWalk(chain: FolderTree.chain(to: deep), from: level)

        XCTAssertNil(walk.target)
        XCTAssertEqual(walk.open.map(\.title), ["/", "soquel-reveal", "home"])
    }

    /// A level whose children have not been read yet is reported so reveal()
    /// can wait for the load and carry on from there.
    func testTheWalkPausesAtALevelThatHasNotLoaded() {
        let home = child(base, "home")
        let documents = child(home, "Documents")
        let level = roots(homeChildren: [], homeLoaded: false)

        let walk = SidebarViewController.revealWalk(chain: FolderTree.chain(to: documents), from: level)

        XCTAssertEqual(walk.pending?.url, home)
        XCTAssertNil(walk.target, "nothing is selected until the load has come back")
        XCTAssertEqual(walk.open.map(\.title), ["/", "soquel-reveal", "home"],
                       "the unloaded level is opened, which starts its load")
    }

    /// The folder itself may be the one that has not loaded; it is still the
    /// end of the chain, and the second pass selects it.
    func testTheFolderIsSelectedOnceItsOwnLevelHasLoaded() {
        let documents = child(child(base, "home"), "Documents")
        let chain = FolderTree.chain(to: documents)

        let unloaded = roots(homeChildren: [folder(documents, loaded: false)])
        XCTAssertNil(SidebarViewController.revealWalk(chain: chain, from: unloaded).target)

        let loaded = roots(homeChildren: [folder(documents)])
        XCTAssertEqual(SidebarViewController.revealWalk(chain: chain, from: loaded).target?.url, documents)
    }

    func testAFolderOnNoKnownRootFindsNothing() {
        let walk = SidebarViewController.revealWalk(
            chain: FolderTree.chain(to: URL(fileURLWithPath: "/elsewhere/deep", isDirectory: true)), from: []
        )
        XCTAssertNil(walk.target)
        XCTAssertNil(walk.pending)
        XCTAssertTrue(walk.open.isEmpty)
    }
}

/// The sidebar tells its delegate about a selected row, and the delegate
/// navigates the focused pane to it. AppKit posts selectionDidChange for a
/// programmatic selection as well as a click, so reveal() — which runs because
/// the pane has already moved — must not have its own selection sent back.
final class SweepSidebarSelectionReportTests: XCTestCase {
    private final class DelegateSpy: SidebarDelegate {
        var selected: [URL] = []
        var revealed: [URL] = []
        var searches: [SavedSearch] = []
        var newTabs: [URL] = []

        func sidebar(_ sidebar: SidebarViewController, didSelect url: URL) { selected.append(url) }
        func sidebar(_ sidebar: SidebarViewController, revealFile url: URL) { revealed.append(url) }
        func sidebar(_ sidebar: SidebarViewController, openInNewTab url: URL) { newTabs.append(url) }
        func sidebar(_ sidebar: SidebarViewController, run search: SavedSearch) { searches.append(search) }
        func sidebar(_ sidebar: SidebarViewController, dropFiles urls: [URL], into destination: URL, move: Bool) {}
    }

    private var sidebar: SidebarViewController!
    private var spy: DelegateSpy!

    override func setUp() {
        super.setUp()
        sidebar = SidebarViewController(nibName: nil, bundle: nil)
        spy = DelegateSpy()
        sidebar.delegate = spy
    }

    private func savedSearch() -> SavedSearch {
        SavedSearch(name: "TODOs", query: FileSearch.Query(text: "TODO", root: URL(fileURLWithPath: "/tmp")))
    }

    func testARowTheUserPickedIsPassedOn() {
        let documents = URL(fileURLWithPath: "/tmp", isDirectory: true)
        sidebar.report(selectionOf: SidebarNode(.treeFolder(documents)))
        XCTAssertEqual(spy.selected, [documents])
    }

    func testARowRevealSelectedIsNotPassedOn() {
        let documents = URL(fileURLWithPath: "/tmp", isDirectory: true)
        sidebar.suppressingSelectionReports {
            sidebar.report(selectionOf: SidebarNode(.treeFolder(documents)))
        }
        XCTAssertTrue(spy.selected.isEmpty, "reveal's own selection would navigate the pane a second time")
    }

    /// A saved search re-runs the query, so replaying it costs a whole search.
    func testASavedSearchIsNotRerunByASelectionTheSidebarMade() {
        sidebar.suppressingSelectionReports {
            sidebar.report(selectionOf: SidebarNode(.savedSearch(savedSearch())))
        }
        XCTAssertTrue(spy.searches.isEmpty)

        sidebar.report(selectionOf: SidebarNode(.savedSearch(savedSearch())))
        XCTAssertEqual(spy.searches.count, 1)
    }

    func testClicksAreReportedAgainOnceRevealHasFinished() {
        let documents = URL(fileURLWithPath: "/tmp", isDirectory: true)
        sidebar.suppressingSelectionReports {
            sidebar.suppressingSelectionReports {
                sidebar.report(selectionOf: SidebarNode(.treeFolder(documents)))
            }
            sidebar.report(selectionOf: SidebarNode(.treeFolder(documents)))
        }
        XCTAssertTrue(spy.selected.isEmpty, "nesting must not lift the suppression early")

        sidebar.report(selectionOf: SidebarNode(.treeFolder(documents)))
        XCTAssertEqual(spy.selected, [documents])
    }

    func testAGroupHeaderHasNowhereToGoAndIsNotReported() {
        sidebar.report(selectionOf: SidebarNode(.systemGroup("Folders")))
        XCTAssertTrue(spy.selected.isEmpty)
    }
}

/// The icon picker's symbol buttons.
///
/// The symbol and the text field used to be looked up in a process-wide table
/// keyed by ObjectIdentifier(button) — the button's address. The table neither
/// retained the buttons nor forgot them when the alert went away, so a second
/// run whose buttons landed on addresses the first had freed matched the first
/// run's entries and wrote into a text field that was no longer on screen.
final class SweepIconPickerFieldSetterTests: XCTestCase {
    private func button(symbol: String?) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        if let symbol { button.identifier = NSUserInterfaceItemIdentifier(symbol) }
        return button
    }

    func testAButtonWritesItsOwnSymbolIntoTheField() {
        let field = NSTextField(string: "")
        let setter = IconPicker.FieldSetter(field: field)
        setter.set(button(symbol: "star"))
        XCTAssertEqual(field.stringValue, "star")
    }

    func testEachButtonCarriesADifferentSymbol() {
        let field = NSTextField(string: "")
        let setter = IconPicker.FieldSetter(field: field)
        for symbol in SidebarIcon.suggestedSymbols.prefix(12) {
            setter.set(button(symbol: symbol))
            XCTAssertEqual(field.stringValue, symbol)
        }
    }

    func testASecondRunOfThePickerDoesNotWriteIntoTheFirstRunsField() {
        let first = NSTextField(string: "")
        IconPicker.FieldSetter(field: first).set(button(symbol: "star"))

        let second = NSTextField(string: "")
        IconPicker.FieldSetter(field: second).set(button(symbol: "folder"))

        XCTAssertEqual(second.stringValue, "folder", "the button writes into the field on screen")
        XCTAssertEqual(first.stringValue, "star", "the earlier run's field is left alone")
    }

    /// A setter only answers for buttons carrying a symbol, so a control from
    /// anywhere else cannot overwrite what has been typed.
    func testAButtonWithNoSymbolLeavesTheFieldAlone() {
        let field = NSTextField(string: "keep me")
        let setter = IconPicker.FieldSetter(field: field)
        setter.set(button(symbol: nil))
        setter.set(button(symbol: ""))
        XCTAssertEqual(field.stringValue, "keep me")
    }
}
