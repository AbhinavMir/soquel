import AppKit
import XCTest
@testable import SoquelCore

final class CommandRegistryTests: XCTestCase {
    override func tearDown() {
        CommandRegistry.resetAllShortcuts()
        super.tearDown()
    }

    /// Two commands sharing a shortcut means one of them silently never fires.
    /// ⇧⌘W was once bound to both Close Window and Close Pane, and pressing it
    /// quit the app instead of closing a pane.
    func testNoDuplicateDefaultShortcuts() {
        var seen: [Shortcut: [String]] = [:]
        for command in CommandRegistry.all {
            guard let shortcut = command.defaultShortcut else { continue }
            seen[shortcut, default: []].append(command.title)
        }
        let duplicates = seen.filter { $0.value.count > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "shortcut bound more than once: " + duplicates
                .map { "\($0.key.display) → \($0.value.joined(separator: " / "))" }
                .joined(separator: "; ")
        )
    }

    func testEveryCommandHasAUniqueIdentifier() {
        let ids = CommandRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "command identifiers must be unique")
    }

    func testMenuIsBuiltFromTheRegistry() {
        let menu = AppDelegate().makeMainMenu()
        var titles: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                titles.insert(item.title)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        for command in CommandRegistry.all {
            XCTAssertTrue(titles.contains(command.title), "\(command.title) is missing from the menu")
        }
        XCTAssertTrue(titles.contains("Settings…"), "Settings must be reachable from the app menu")
    }

    /// The menu's key equivalent has to be the remapped one, or the palette
    /// would advertise a shortcut that does nothing.
    func testRemappingFlowsIntoTheMenu() {
        guard let command = CommandRegistry.command(id: "pane.splitVertical") else {
            return XCTFail("missing command")
        }
        CommandRegistry.setShortcut(Shortcut("j", [.command, .control]), for: command)
        defer { CommandRegistry.resetShortcut(for: command) }

        XCTAssertEqual(CommandRegistry.command(id: "pane.splitVertical")?.shortcut?.display, "⌃⌘J")

        let menu = AppDelegate().makeMainMenu()
        var found: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.title == command.title { found = item }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        XCTAssertEqual(found?.keyEquivalent, "j")
        XCTAssertEqual(found?.keyEquivalentModifierMask, [.command, .control])
    }

    func testUnbindingRemovesTheShortcutWithoutRestoringTheDefault() {
        guard let command = CommandRegistry.command(id: "view.refresh") else {
            return XCTFail("missing command")
        }
        XCTAssertNotNil(command.defaultShortcut)
        CommandRegistry.setShortcut(nil, for: command)
        defer { CommandRegistry.resetShortcut(for: command) }
        XCTAssertNil(CommandRegistry.command(id: "view.refresh")?.shortcut)

        CommandRegistry.resetShortcut(for: command)
        XCTAssertNotNil(CommandRegistry.command(id: "view.refresh")?.shortcut)
    }

    func testConflictDetectionFindsTheOtherCommand() {
        guard let refresh = CommandRegistry.command(id: "view.refresh"),
              let palette = CommandRegistry.command(id: "view.palette")
        else { return XCTFail("missing commands") }

        let clashes = CommandRegistry.conflicts(with: palette.defaultShortcut!, excluding: refresh)
        XCTAssertEqual(clashes.map(\.id), ["view.palette"])

        XCTAssertTrue(
            CommandRegistry.conflicts(with: Shortcut("§", [.command, .control, .option]), excluding: refresh).isEmpty
        )
    }

    func testShortcutDisplayUsesStandardSymbols() {
        XCTAssertEqual(Shortcut("d", [.command, .shift]).display, "⇧⌘D")
        XCTAssertEqual(Shortcut("\u{8}", [.command]).display, "⌘⌫")
        XCTAssertEqual(Shortcut("\t", [.control, .shift]).display, "⌃⇧⇥")
        XCTAssertEqual(Shortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]).display, "⌘↑")
    }
}

final class SortOrderTests: XCTestCase {
    private func item(_ name: String, size: Int64 = 0, kind: String = "Doc", ext: String = "") -> FileItem {
        let full = ext.isEmpty ? name : "\(name).\(ext)"
        return FileItem(url: URL(fileURLWithPath: "/tmp/\(full)"), name: full, isDirectory: false,
                        isPackage: false, isSymlink: false, isHidden: false,
                        size: size, modified: .distantPast, created: .distantPast, kind: kind)
    }

    /// Says what it starts from rather than leaning on the default, which is
    /// a product decision and free to change.
    func testClickingTheSameColumnFlipsDirection() {
        var order = SortOrder(descriptors: [SortDescriptorSpec(key: .name, ascending: true)])
        XCTAssertEqual(order.primary?.ascending, true)
        order.makePrimary(.name)
        XCTAssertEqual(order.primary?.ascending, false)
    }

    func testClickingANewColumnMakesItPrimaryAndKeepsTheOldOne() {
        var order = SortOrder(descriptors: [SortDescriptorSpec(key: .name, ascending: true)])
        order.makePrimary(.size)
        XCTAssertEqual(order.descriptors.map(\.key), [.size, .name])
    }

    /// A folder is opened to see what changed far more often than to read it
    /// alphabetically, so the newest thing is at the top.
    func testTheDefaultIsNewestFirst() {
        XCTAssertEqual(SortOrder.default.primary?.key, .modified)
        XCTAssertEqual(SortOrder.default.primary?.ascending, false)
    }

    func testSecondaryKeysBreakTiesInOrder() {
        var order = SortOrder(descriptors: [SortDescriptorSpec(key: .kind, ascending: true)])
        order.addSecondary(.size)
        XCTAssertEqual(order.descriptors.map(\.key), [.kind, .size])

        let items = [
            item("b", size: 10, kind: "Text"),
            item("a", size: 99, kind: "Text"),
            item("c", size: 1, kind: "Image"),
        ]
        let sorted = sortItems(items, order: order, foldersFirst: false)
        XCTAssertEqual(sorted.map(\.name), ["c", "b", "a"])
    }

    func testDepthIsCapped() {
        var order = SortOrder.default
        for key in [SortKey.size, .kind, .modified, .created, .ext] {
            order.addSecondary(key)
        }
        XCTAssertEqual(order.descriptors.count, SortOrder.maximumDepth)
    }

    func testReverseFlipsEveryKey() {
        var order = SortOrder(descriptors: [
            SortDescriptorSpec(key: .kind, ascending: true),
            SortDescriptorSpec(key: .size, ascending: false),
        ])
        order.reverse()
        XCTAssertEqual(order.descriptors.map(\.ascending), [false, true])
    }

    func testClearSecondaryKeepsThePrimary() {
        var order = SortOrder(descriptors: [
            SortDescriptorSpec(key: .kind, ascending: true),
            SortDescriptorSpec(key: .size, ascending: false),
        ])
        order.clearSecondary()
        XCTAssertEqual(order.descriptors.map(\.key), [.kind])
    }

    func testSummaryNamesEveryKeyInOrder() {
        let order = SortOrder(descriptors: [
            SortDescriptorSpec(key: .kind, ascending: true),
            SortDescriptorSpec(key: .size, ascending: false),
        ])
        XCTAssertEqual(order.summary, "Kind ↑, then Size ↓")
    }

    func testSortByExtension() {
        let items = [item("b", ext: "zip"), item("a", ext: "txt"), item("c", ext: "txt")]
        let order = SortOrder(descriptors: [SortDescriptorSpec(key: .ext, ascending: true)])
        XCTAssertEqual(sortItems(items, order: order, foldersFirst: false).map(\.name),
                       ["a.txt", "c.txt", "b.zip"])
    }

    func testRoundTripsThroughPreferences() throws {
        let order = SortOrder(descriptors: [
            SortDescriptorSpec(key: .size, ascending: false),
            SortDescriptorSpec(key: .name, ascending: true),
        ])
        let data = try JSONEncoder().encode(order)
        XCTAssertEqual(try JSONDecoder().decode(SortOrder.self, from: data), order)
    }
}

final class GitStatusTests: XCTestCase {
    func testPorcelainCodesMapToStates() {
        XCTAssertEqual(GitState.from(porcelainCode: " M"), .modified)
        XCTAssertEqual(GitState.from(porcelainCode: "M "), .modified)
        XCTAssertEqual(GitState.from(porcelainCode: "A "), .added)
        XCTAssertEqual(GitState.from(porcelainCode: " D"), .deleted)
        XCTAssertEqual(GitState.from(porcelainCode: "??"), .untracked)
        XCTAssertEqual(GitState.from(porcelainCode: "!!"), .ignored)
        XCTAssertEqual(GitState.from(porcelainCode: "UU"), .conflicted)
        XCTAssertEqual(GitState.from(porcelainCode: "AA"), .conflicted)
        XCTAssertNil(GitState.from(porcelainCode: "  "))
    }

    /// Status must be legible without colour vision.
    func testEveryStateHasADistinctBadge() {
        let badges = [GitState.modified, .added, .deleted, .renamed, .untracked, .ignored, .conflicted]
            .map(\.badge)
        XCTAssertEqual(badges.count, Set(badges).count)
        XCTAssertTrue(GitState.clean.badge.isEmpty)
    }

    func testParsingMarksParentFoldersAsChanged() {
        let root = URL(fileURLWithPath: "/repo")
        let statuses = GitStatusReader.parse(porcelainZ: " M src/deep/file.swift\0", root: root)
        XCTAssertEqual(statuses["/repo/src/deep/file.swift"], .modified)
        XCTAssertEqual(statuses["/repo/src/deep"], .modified)
        XCTAssertEqual(statuses["/repo/src"], .modified)
        XCTAssertNil(statuses["/repo"], "the repository root itself is not badged")
    }

    /// -z output is NUL-separated and unquoted, so awkward filenames survive.
    func testParsingHandlesSpacesAndQuotesInNames() {
        let root = URL(fileURLWithPath: "/repo")
        let statuses = GitStatusReader.parse(porcelainZ: "?? my \"odd\" file.txt\0 M other file.md\0", root: root)
        XCTAssertEqual(statuses["/repo/my \"odd\" file.txt"], .untracked)
        XCTAssertEqual(statuses["/repo/other file.md"], .modified)
    }

    func testEmptyOutputYieldsNoStatuses() {
        XCTAssertTrue(GitStatusReader.parse(porcelainZ: "", root: URL(fileURLWithPath: "/repo")).isEmpty)
    }
}
