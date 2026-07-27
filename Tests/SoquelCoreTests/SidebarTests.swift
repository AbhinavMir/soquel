import AppKit
import XCTest
@testable import SoquelCore

final class SidebarLayoutTests: XCTestCase {
    private func layout() -> SidebarLayout {
        SidebarLayout(groups: [
            SidebarGroup(title: "Favourites", items: [
                SidebarItem(path: "/tmp/a"),
                SidebarItem(path: "/tmp/b"),
            ]),
            SidebarGroup(title: "Work", items: [
                SidebarItem(path: "/tmp/c"),
            ]),
        ])
    }

    func testDisplayNameOverridesTheFolderName() {
        var item = SidebarItem(path: "/tmp/some-long-folder")
        XCTAssertEqual(item.title, "some-long-folder")
        item.displayName = "Client work"
        XCTAssertEqual(item.title, "Client work")
        // An empty rename falls back rather than showing a blank row.
        item.displayName = ""
        XCTAssertEqual(item.title, "some-long-folder")
    }

    func testTildePathsExpand() {
        let item = SidebarItem(path: "~/Documents")
        XCTAssertEqual(item.url.path,
                       FileManager.default.homeDirectoryForCurrentUser.path + "/Documents")
    }

    func testPinningTheSameFolderTwiceIsANoOp() {
        var model = layout()
        let group = model.groups[0].id
        model.addItem(SidebarItem(path: "/tmp/a"), toGroup: group)
        XCTAssertEqual(model.groups[0].items.count, 2, "no duplicate row")
    }

    func testPinningIntoASpecificGroup() {
        var model = layout()
        let work = model.groups[1].id
        model.addItem(SidebarItem(path: "/tmp/new"), toGroup: work)
        XCTAssertEqual(model.groups[1].items.map(\.path), ["/tmp/c", "/tmp/new"])
        XCTAssertEqual(model.groups[0].items.count, 2, "the other group is untouched")
    }

    func testRemovingAnItem() {
        var model = layout()
        let id = model.groups[0].items[0].id
        model.removeItem(id: id)
        XCTAssertEqual(model.groups[0].items.map(\.path), ["/tmp/b"])
    }

    func testChangingIconAndName() {
        var model = layout()
        let id = model.groups[0].items[0].id
        model.updateItem(id: id) { $0.icon = "star"; $0.displayName = "Starred" }
        XCTAssertEqual(model.item(id: id)?.icon, "star")
        XCTAssertEqual(model.item(id: id)?.title, "Starred")
    }

    // MARK: - Groups

    func testAddingAndRenamingAGroup() {
        var model = layout()
        let id = model.addGroup(title: "Media")
        XCTAssertEqual(model.groups.count, 3)
        model.renameGroup(id: id, to: "Video")
        XCTAssertEqual(model.group(id: id)?.title, "Video")
    }

    func testRemovingAGroupTakesItsItems() {
        var model = layout()
        let id = model.groups[1].id
        model.removeGroup(id: id)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertNil(model.groups.first { $0.id == id })
    }

    // MARK: - Reordering

    func testMovingAnItemBetweenGroups() {
        var model = layout()
        let id = model.groups[0].items[0].id
        let work = model.groups[1].id
        model.move(itemID: id, toGroup: work, at: 0)
        XCTAssertEqual(model.groups[0].items.map(\.path), ["/tmp/b"])
        XCTAssertEqual(model.groups[1].items.map(\.path), ["/tmp/a", "/tmp/c"])
    }

    /// Dragging down inside one group has to account for the row being lifted
    /// out before it is put back, or it lands one place short.
    func testReorderingWithinAGroup() {
        var model = layout()
        let first = model.groups[0].items[0].id
        let group = model.groups[0].id
        model.move(itemID: first, toGroup: group, at: 2)
        XCTAssertEqual(model.groups[0].items.map(\.path), ["/tmp/b", "/tmp/a"])
    }

    func testMovingUpwardsWithinAGroup() {
        var model = layout()
        let second = model.groups[0].items[1].id
        let group = model.groups[0].id
        model.move(itemID: second, toGroup: group, at: 0)
        XCTAssertEqual(model.groups[0].items.map(\.path), ["/tmp/b", "/tmp/a"])
    }

    func testMovingPastTheEndClamps() {
        var model = layout()
        let id = model.groups[1].items[0].id
        let favourites = model.groups[0].id
        model.move(itemID: id, toGroup: favourites, at: 99)
        XCTAssertEqual(model.groups[0].items.map(\.path), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    // MARK: - Persistence

    func testLayoutRoundTripsThroughJSON() throws {
        let model = layout()
        let data = try JSONEncoder().encode(model)
        XCTAssertEqual(try JSONDecoder().decode(SidebarLayout.self, from: data), model)
    }

    func testDefaultLayoutOnlyPinsFoldersThatExist() {
        for item in SidebarLayout.defaultLayout.groups.flatMap(\.items) {
            XCTAssertTrue(item.exists, "\(item.path) is offered by default but does not exist")
        }
    }
}

final class SidebarIconTests: XCTestCase {
    func testSymbolNameResolvesToAnImage() {
        let item = SidebarItem(path: "/tmp", icon: "star")
        XCTAssertNotNil(SidebarIcon.image(for: item))
    }

    func testEmojiIsRecognisedAndDrawn() {
        XCTAssertTrue(SidebarIcon.isEmoji("📁"))
        XCTAssertTrue(SidebarIcon.isEmoji("🚀"))
        XCTAssertFalse(SidebarIcon.isEmoji("star"))
        XCTAssertFalse(SidebarIcon.isEmoji(""))

        let image = SidebarIcon.emojiImage("📁", size: 16)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    /// An icon that is neither a symbol nor an emoji falls back to the folder's
    /// own icon rather than showing nothing.
    func testUnknownIconFallsBackToTheFileIcon() {
        let item = SidebarItem(path: NSTemporaryDirectory(), icon: "not-a-real-symbol-name")
        XCTAssertNotNil(SidebarIcon.image(for: item))
    }

    func testMissingFolderStillProducesAnIcon() {
        let item = SidebarItem(path: "/tmp/definitely-missing-\(UUID().uuidString)")
        XCTAssertFalse(item.exists)
        XCTAssertNotNil(SidebarIcon.image(for: item), "a broken shortcut still needs a row")
    }

    func testEverySuggestedSymbolExists() {
        for symbol in SidebarIcon.suggestedSymbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) is offered in the picker but is not a real SF Symbol"
            )
        }
    }
}

final class FolderTreeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testListsOnlySubdirectories() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let children = FolderTree.children(of: dir, showHidden: false)
        XCTAssertEqual(children.map(\.lastPathComponent), ["sub"])
    }

    func testHiddenFoldersFollowTheSetting() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".hidden"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FolderTree.children(of: dir, showHidden: false).isEmpty)
        XCTAssertEqual(FolderTree.children(of: dir, showHidden: true).map(\.lastPathComponent), [".hidden"])
    }

    /// An .app is a folder. Expanding it in a tree would show its innards,
    /// which is never what someone browsing wants.
    func testPackagesAreLeaves() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Thing.app/Contents"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FolderTree.children(of: dir, showHidden: false).isEmpty)
    }

    /// A symlink pointing back up the tree would expand forever.
    func testSymlinksAreNotFollowed() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("loop"),
                                                   withDestinationURL: dir)

        let children = FolderTree.children(of: dir, showHidden: false)
        XCTAssertEqual(children.map(\.lastPathComponent), ["real"])
    }

    func testChildrenAreSortedNaturally() throws {
        for name in ["item10", "item2", "Item1"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertEqual(FolderTree.children(of: dir, showHidden: false).map(\.lastPathComponent),
                       ["Item1", "item2", "item10"])
    }

    func testUnreadableFolderYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(FolderTree.children(of: URL(fileURLWithPath: "/does/not/exist"), showHidden: false).isEmpty)
    }

    /// The chain is what reveal walks down to follow the active pane.
    func testChainRunsFromRootToLeaf() {
        let chain = FolderTree.chain(to: URL(fileURLWithPath: "/usr/local/share")).map(\.path)
        XCTAssertEqual(chain, ["/", "/usr", "/usr/local", "/usr/local/share"])
    }

    func testRootsIncludeHome() {
        XCTAssertTrue(FolderTree.roots.contains { $0.path == FileManager.default.homeDirectoryForCurrentUser.path })
    }
}

/// Drops used to land at the bottom whatever they were aimed at: the only drop
/// the outline view accepted was the one onto the group itself, which arrives
/// with a child index of -1 and was read as "append".
final class SidebarDropPositionTests: XCTestCase {
    private func layoutOfThree() -> (SidebarLayout, UUID) {
        var layout = SidebarLayout(groups: [])
        let group = layout.addGroup(title: "Favourites")
        for name in ["one", "two", "three"] {
            layout.addItem(SidebarItem(path: "/tmp/\(name)"), toGroup: group)
        }
        return (layout, group)
    }

    private func names(_ layout: SidebarLayout, _ group: UUID) -> [String] {
        (layout.group(id: group)?.items ?? []).map { $0.url.lastPathComponent }
    }

    func testAnItemDroppedAtTheTopGoesToTheTop() {
        var (layout, group) = layoutOfThree()
        layout.insertItem(SidebarItem(path: "/tmp/new"), toGroup: group, at: 0)
        XCTAssertEqual(names(layout, group), ["new", "one", "two", "three"])
    }

    func testAnItemDroppedInTheMiddleGoesThere() {
        var (layout, group) = layoutOfThree()
        layout.insertItem(SidebarItem(path: "/tmp/new"), toGroup: group, at: 2)
        XCTAssertEqual(names(layout, group), ["one", "two", "new", "three"])
    }

    func testAPositionPastTheEndIsClampedRatherThanCrashing() {
        var (layout, group) = layoutOfThree()
        layout.insertItem(SidebarItem(path: "/tmp/new"), toGroup: group, at: 99)
        XCTAssertEqual(names(layout, group).last, "new")
    }

    func testDroppingSomethingAlreadyThereChangesNothing() {
        var (layout, group) = layoutOfThree()
        layout.insertItem(SidebarItem(path: "/tmp/two"), toGroup: group, at: 0)
        XCTAssertEqual(names(layout, group), ["one", "two", "three"])
    }

    /// Reordering by drag: moving the first item to the end and back.
    func testReorderingPutsTheItemWhereItWasAimed() {
        var (layout, group) = layoutOfThree()
        let first = layout.group(id: group)!.items[0].id
        layout.move(itemID: first, toGroup: group, at: 3)
        XCTAssertEqual(names(layout, group), ["two", "three", "one"])

        let moved = layout.group(id: group)!.items[2].id
        layout.move(itemID: moved, toGroup: group, at: 0)
        XCTAssertEqual(names(layout, group), ["one", "two", "three"])
    }
}
