import AppKit

/// A key combination, stored so it can be persisted and compared.
struct Shortcut: Codable, Equatable, Hashable {
    /// The `keyEquivalent` string AppKit expects: a lowercase character, or a
    /// function-key scalar for arrows and similar.
    var key: String
    var modifiers: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifiers = modifiers.rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// How the combination is written in menus, e.g. `⇧⌘D`.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.symbol(for: key)
    }

    static func symbol(for key: String) -> String {
        switch key {
        case "\u{8}", "\u{7F}": return "⌫"
        case "\t": return "⇥"
        case "\r", "\n": return "↩"
        case " ": return "Space"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }

    /// Parses what a user typed into the shortcut recorder.
    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }

        let key: String
        switch event.keyCode {
        case 126: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 125: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 123: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 48: key = "\t"
        case 51: key = "\u{8}"
        case 36: key = "\r"
        case 49: key = " "
        default: key = characters.lowercased()
        }

        // A bare letter would swallow typing everywhere; require a modifier
        // other than shift alone.
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        return Shortcut(key, flags)
    }
}

/// Everything the application can do. The menu bar, the command palette, and
/// the keyboard settings all read this one list, so a command cannot appear in
/// one place with a shortcut that does not match another.
struct Command {
    /// Stable identifier, used as the persistence key for a remapping.
    let id: String
    let title: String
    let selector: Selector
    let defaultShortcut: Shortcut?
    /// Carried into the menu item for commands that share a selector, such as
    /// the copy-path variants.
    let representedObject: String?
    /// False for commands that only make sense from a menu (Quit, Hide).
    let inPalette: Bool

    init(
        _ id: String,
        _ title: String,
        _ selector: Selector,
        _ defaultShortcut: Shortcut? = nil,
        representedObject: String? = nil,
        inPalette: Bool = true
    ) {
        self.id = id
        self.title = title
        self.selector = selector
        self.defaultShortcut = defaultShortcut
        self.representedObject = representedObject
        self.inPalette = inPalette
    }

    /// The shortcut in force: the user's remapping when set, otherwise the
    /// default. A command the user has explicitly unbound has none.
    var shortcut: Shortcut? { CommandRegistry.shortcut(for: self) }
}

enum MenuEntry {
    case command(Command)
    case separator
}

struct MenuSection {
    let title: String
    let entries: [MenuEntry]

    var commands: [Command] {
        entries.compactMap { if case .command(let c) = $0 { return c } else { return nil } }
    }
}

enum CommandRegistry {
    // MARK: - Remapping storage

    private static let defaultsKey = "shortcutOverrides"

    /// id → shortcut. A stored entry with a nil value means "no shortcut".
    ///
    /// settings.json can be edited by hand while the app runs, so the cache
    /// follows outside edits. Without the reload the rebuilt menu would
    /// reinstall the old shortcuts, and the next in-app remap would write the
    /// stale set back over the user's edit. The observer posts the shortcuts
    /// notification itself so the menu rebuild reads fresh values whatever
    /// order the settings observers fire in.
    private static var overrides: [String: Shortcut?] = {
        // The token is never removed: the registry lives for the whole app.
        _ = NotificationCenter.default.addObserver(
            forName: .soquelSettingsChanged, object: nil, queue: .main
        ) { _ in
            overrides = load()
            NotificationCenter.default.post(name: .soquelShortcutsChanged, object: nil)
        }
        return load()
    }()

    private static func load() -> [String: Shortcut?] {
        guard let decoded = Settings.decode([String: Shortcut?].self, forKey: defaultsKey)
        else { return [:] }
        return decoded
    }

    private static func persist() {
        Settings.encode(overrides, forKey: defaultsKey)
        NotificationCenter.default.post(name: .soquelShortcutsChanged, object: nil)
    }

    static func shortcut(for command: Command) -> Shortcut? {
        if let override = overrides[command.id] { return override }
        return command.defaultShortcut
    }

    static func setShortcut(_ shortcut: Shortcut?, for command: Command) {
        overrides[command.id] = .some(shortcut)
        persist()
    }

    static func resetShortcut(for command: Command) {
        overrides.removeValue(forKey: command.id)
        persist()
    }

    static func resetAllShortcuts() {
        overrides.removeAll()
        persist()
    }

    static func isRemapped(_ command: Command) -> Bool { overrides[command.id] != nil }

    /// Commands other than `command` that already use `shortcut`.
    static func conflicts(with shortcut: Shortcut, excluding command: Command) -> [Command] {
        all.filter { $0.id != command.id && $0.shortcut == shortcut }
    }

    // MARK: - The commands

    static var all: [Command] { sections.flatMap(\.commands) }

    static func command(id: String) -> Command? { all.first { $0.id == id } }

    static var sections: [MenuSection] {
        [fileSection, editSection, pathSection, viewSection, toolsSection, paneSection, goSection]
    }

    private typealias M = MainWindowController

    static let fileSection = MenuSection(title: "File", entries: [
        .command(Command("file.newWindow", "New Window", #selector(AppDelegate.newWindow(_:)), Shortcut("n"))),
        .command(Command("file.newTab", "New Tab", #selector(M.menuNewTab(_:)), Shortcut("t"))),
        .command(Command("file.newFolder", "New Folder", #selector(M.menuNewFolder(_:)), Shortcut("n", [.command, .shift]))),
        .command(Command("file.newFile", "New File", #selector(M.menuNewFile(_:)), Shortcut("n", [.command, .control]))),
        .separator,
        .command(Command("file.open", "Open", #selector(M.menuOpen(_:)), Shortcut("o"))),
        .command(Command("file.openArchive", "Look Inside Archive…", #selector(M.menuOpenArchive(_:)), Shortcut("o", [.command, .shift]))),
        .command(Command("file.openTerminal", "Open in Terminal", #selector(M.menuOpenInTerminal(_:)), Shortcut("t", [.command, .control]))),
        .command(Command("file.openEditor", "Open in Editor", #selector(M.menuOpenInEditor(_:)), Shortcut("e", [.command, .control]))),
        .command(Command("file.reveal", "Reveal in Finder", #selector(M.menuRevealInFinder(_:)), Shortcut("r", [.command, .shift]))),
        .separator,
        .command(Command("file.rename", "Rename", #selector(M.menuRename(_:)))),
        .command(Command("file.batchRename", "Rename Many…", #selector(M.menuBatchRename(_:)), Shortcut("r", [.command, .control]))),
        // Not ⌃⌘D: macOS takes that for looking a word up in the dictionary
        // before any application sees it, so the item's key never fired.
        .command(Command("file.duplicate", "Duplicate", #selector(M.menuDuplicate(_:)), Shortcut("d", [.command, .control, .shift]))),
        .command(Command("file.symlink", "Make Symlink", #selector(M.menuMakeSymlink(_:)))),
        .command(Command("file.compress", "Compress", #selector(M.menuCompress(_:)))),
        .command(Command("file.trash", "Move to Trash", #selector(M.menuTrash(_:)), Shortcut("\u{8}"))),
        .command(Command("file.delete", "Delete Permanently…", #selector(M.menuDeletePermanently(_:)), Shortcut("\u{8}", [.command, .option]))),
        .separator,
        .separator,
        .command(Command("shelf.add", "Add to Shelf", #selector(M.menuAddToShelf(_:)), Shortcut("a", [.command, .control]))),
        .command(Command("shelf.show", "Show Shelf", #selector(M.menuShowShelf(_:)), Shortcut("b", [.command, .control]))),
        .command(Command("shelf.clear", "Clear Shelf", #selector(M.menuClearShelf(_:)))),
        .separator,
        .command(Command("file.closeTab", "Close Tab", #selector(M.menuCloseTab(_:)), Shortcut("w"))),
        .command(Command("file.closeWindow", "Close Window", #selector(NSWindow.performClose(_:)), Shortcut("w", [.command, .option]), inPalette: false)),
    ])

    static let editSection = MenuSection(title: "Edit", entries: [
        .command(Command("edit.undo", "Undo", Selector(("undo:")), Shortcut("z"))),
        .separator,
        .command(Command("edit.cut", "Cut", #selector(NSText.cut(_:)), Shortcut("x"))),
        .command(Command("edit.copy", "Copy", #selector(NSText.copy(_:)), Shortcut("c"))),
        .command(Command("edit.paste", "Paste", #selector(NSText.paste(_:)), Shortcut("v"))),
        .separator,
        .command(Command("edit.selectAll", "Select All", #selector(M.selectAll(_:)), Shortcut("a"))),
        .command(Command("edit.invertSelection", "Invert Selection", #selector(M.menuInvertSelection(_:)))),
        .separator,
        .command(Command("edit.filter", "Filter This Folder", #selector(M.menuFilter(_:)), Shortcut("f"))),
        .command(Command("edit.findFiles", "Find Files by Name…", #selector(M.menuFindByName(_:)), Shortcut("f", [.command, .option]))),
        .command(Command("edit.findContents", "Find in File Contents…", #selector(M.menuFindInContents(_:)), Shortcut("f", [.command, .shift]))),
        .command(Command("edit.findMeaning", "Find by Meaning…", #selector(M.menuFindByMeaning(_:)), Shortcut("f", [.command, .control]))),
        .command(Command("edit.indexFolder", "Index This Folder for Meaning", #selector(M.menuIndexFolder(_:)))),
        .command(Command("edit.rebuildIndex", "Rebuild the Meaning Index", #selector(M.menuRebuildIndex(_:)))),
    ])

    static var pathSection: MenuSection {
        var entries: [MenuEntry] = PathFormat.allCases.map { format in
            .command(Command(
                "path.\(format.id)",
                "Copy \(format.title)",
                #selector(M.menuCopyPath(_:)),
                // ⌥⌘C is what Finder binds Copy as Pathname to, so it is the
                // one people already reach for.
                format == .absolute ? Shortcut("c", [.command, .option]) : nil,
                representedObject: format.title
            ))
        }
        entries.append(.command(Command(
            "path.gitRelative", "Copy Path Relative to Git Root",
            #selector(M.menuCopyRelativePath(_:)), Shortcut("c", [.command, .option, .shift])
        )))
        return MenuSection(title: "Path", entries: entries)
    }

    static let viewSection = MenuSection(title: "View", entries: [
        // ⇧⌘P, as every editor with a command palette uses. ⌘K was the old
        // binding and is still reachable by remapping it in Settings.
        .command(Command("view.palette", "Command Palette…", #selector(M.menuCommandPalette(_:)), Shortcut("p", [.command, .shift]))),
        .separator,
        .command(Command("view.listView", "As List", #selector(M.menuUseListView(_:)), Shortcut("1", [.command, .option]))),
        .command(Command("view.iconView", "As Icons", #selector(M.menuUseIconView(_:)), Shortcut("2", [.command, .option]))),
        .command(Command("view.zoomIn", "Bigger Icons", #selector(M.menuZoomIn(_:)), Shortcut("+"))),
        .command(Command("view.zoomOut", "Smaller Icons", #selector(M.menuZoomOut(_:)), Shortcut("-"))),
        .command(Command("view.zoomReset", "Default Icon Size", #selector(M.menuZoomReset(_:)), Shortcut("0"))),
        .command(Command("view.columnView", "As Columns", #selector(M.menuUseColumnView(_:)), Shortcut("3", [.command, .option]))),
        .separator,
        .command(Command("view.hidden", "Toggle Hidden Files", #selector(M.menuToggleHidden(_:)), Shortcut(".", [.command, .shift]))),
        .command(Command("view.foldersFirst", "Folders First", #selector(M.menuToggleFoldersFirst(_:)))),
        .command(Command("view.gitStatus", "Show Git Status", #selector(M.menuToggleGitStatus(_:)))),
        .command(Command("view.folderSizes", "Calculate Folder Sizes", #selector(M.menuToggleFolderSizes(_:)))),
        .command(Command("view.transfers", "Show Transfers", #selector(M.menuShowTransfers(_:)), Shortcut("j", [.command, .option]))),
        .command(Command("view.fitColumns", "Fit Columns to Content", #selector(M.menuFitColumns(_:)), Shortcut("=", [.command, .option]))),
        .command(Command("view.autoFitColumns", "Fit Columns Automatically", #selector(M.menuToggleAutoFitColumns(_:)))),
        .command(Command("view.keyboardFirst", "Keyboard-First Keys (j k h l)", #selector(M.menuToggleKeyboardFirst(_:)))),
        .command(Command("app.copyLogs", "Copy Recent Logs", #selector(M.menuCopyRecentLogs(_:)))),
        .command(Command("app.revealLogs", "Reveal Logs in Finder", #selector(M.menuRevealLogs(_:)))),
        .command(Command("view.themes", "Themes…", #selector(M.menuShowThemes(_:)))),
        .command(Command("view.revealThemes", "Reveal Themes Folder", #selector(M.menuRevealThemes(_:)))),
        .command(Command("view.editSettings", "Edit settings.json", #selector(M.menuEditSettingsFile(_:)), inPalette: true)),
        .command(Command("view.revealSettings", "Reveal settings.json in Finder", #selector(M.menuRevealSettingsFile(_:)), inPalette: true)),
        .command(Command("view.diskMap", "Disk Map…", #selector(M.menuShowDiskMap(_:)), Shortcut("u", [.command, .shift]))),
        .command(Command("view.inspector", "Show Preview", #selector(M.menuToggleInspector(_:)), Shortcut("i", [.command, .option]))),
        .command(Command("view.folderTree", "Show Folder Tree", #selector(M.menuToggleFolderTree(_:)), Shortcut("t", [.command, .shift]))),
        .command(Command("view.syncBrowsing", "Sync Browsing", #selector(M.menuToggleSyncBrowsing(_:)))),
        .command(Command("view.perFolder", "Remember View Per Folder", #selector(M.menuTogglePerFolderViews(_:)))),
        .command(Command("view.sidebar", "Toggle Sidebar", #selector(M.menuToggleSidebar(_:)), Shortcut("s", [.command, .control]))),
        .command(Command("view.refresh", "Refresh", #selector(M.menuRefresh(_:)), Shortcut("r"))),
        .separator,
        .command(Command("view.sortName", "Sort by Name", #selector(M.menuSortByName(_:)), Shortcut("1", [.command, .control]))),
        .command(Command("view.sortSize", "Sort by Size", #selector(M.menuSortBySize(_:)), Shortcut("2", [.command, .control]))),
        .command(Command("view.sortKind", "Sort by Kind", #selector(M.menuSortByKind(_:)), Shortcut("3", [.command, .control]))),
        .command(Command("view.sortDate", "Sort by Date Modified", #selector(M.menuSortByDate(_:)), Shortcut("4", [.command, .control]))),
        .command(Command("view.sortExtension", "Sort by Extension", #selector(M.menuSortByExtension(_:)), Shortcut("5", [.command, .control]))),
        .command(Command("view.sortCreated", "Sort by Date Created", #selector(M.menuSortByCreated(_:)), Shortcut("6", [.command, .control]))),
        .command(Command("view.reverseSort", "Reverse Sort Order", #selector(M.menuReverseSort(_:)), Shortcut("r", [.command, .option]))),
        .command(Command("view.clearSecondarySort", "Clear Secondary Sorts", #selector(M.menuClearSecondarySorts(_:)))),
        .separator,
        .command(Command("view.quickLook", "Quick Look", #selector(M.menuQuickLook(_:)), Shortcut("y"))),
    ])

    static let toolsSection = MenuSection(title: "Tools", entries: [
        .command(Command("tools.duplicates", "Find Duplicates…", #selector(M.menuFindDuplicates(_:)))),
        .command(Command("tools.runCommand", "Run a Command Here…", #selector(M.menuRunCommand(_:)))),
        .separator,
        .command(Command("tools.verifyCopies", "Verify Copies with a Checksum", #selector(M.menuToggleVerifyCopies(_:)))),
    ])

    static let paneSection = MenuSection(title: "Panes", entries: [
        .command(Command("pane.splitVertical", "Split Vertically", #selector(M.menuSplitVertically(_:)), Shortcut("d"))),
        .command(Command("pane.splitHorizontal", "Split Horizontally", #selector(M.menuSplitHorizontally(_:)), Shortcut("d", [.command, .shift]))),
        .command(Command("pane.close", "Close Pane", #selector(M.menuClosePane(_:)), Shortcut("w", [.command, .shift]))),
        .separator,
        .command(Command("pane.focusNext", "Focus Next Pane", #selector(M.menuFocusNextPane(_:)), Shortcut(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]))),
        .command(Command("pane.focusPrevious", "Focus Previous Pane", #selector(M.menuFocusPreviousPane(_:)), Shortcut(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]))),
        .command(Command("pane.focus1", "Focus Pane 1", #selector(M.menuFocusPaneByIndex(_:)), Shortcut("1"), representedObject: "0")),
        .command(Command("pane.focus2", "Focus Pane 2", #selector(M.menuFocusPaneByIndex(_:)), Shortcut("2"), representedObject: "1")),
        .command(Command("pane.focus3", "Focus Pane 3", #selector(M.menuFocusPaneByIndex(_:)), Shortcut("3"), representedObject: "2")),
        .command(Command("pane.focus4", "Focus Pane 4", #selector(M.menuFocusPaneByIndex(_:)), Shortcut("4"), representedObject: "3")),
        .separator,
        // Not ⌥⌘D: macOS takes that for hiding the Dock before any
        // application sees it.
        .command(Command("pane.rotate", "Rotate Split", #selector(M.menuRotatePaneSplit(_:)), Shortcut("d", [.command, .option, .shift]))),
        .command(Command("pane.swap", "Swap Panes", #selector(M.menuSwapPanes(_:)))),
        .command(Command("pane.compare", "Compare Folders…", #selector(M.menuCompareFolders(_:)), Shortcut("k", [.command, .shift]))),
        .command(Command("pane.moveToOpposite", "Move Selection to Opposite Pane", #selector(M.menuMoveToOppositePane(_:)))),
        .command(Command("pane.copyToOpposite", "Copy Selection to Opposite Pane", #selector(M.menuCopyToOppositePane(_:)))),
        .separator,
        .command(Command("pane.nextTab", "Next Tab", #selector(M.menuNextTab(_:)), Shortcut("\t", [.control]))),
        .command(Command("pane.previousTab", "Previous Tab", #selector(M.menuPreviousTab(_:)), Shortcut("\t", [.control, .shift]))),
    ])

    static let goSection = MenuSection(title: "Go", entries: [
        .command(Command("go.connectServer", "Connect to Server…", #selector(M.menuConnectToServer(_:)), Shortcut("k", [.command, .control]))),
        .separator,
        .command(Command("go.back", "Back", #selector(M.menuGoBack(_:)), Shortcut("["))),
        .command(Command("go.forward", "Forward", #selector(M.menuGoForward(_:)), Shortcut("]"))),
        .command(Command("go.up", "Enclosing Folder", #selector(M.menuGoUp(_:)), Shortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!)))),
        .separator,
        .command(Command("go.home", "Home", #selector(M.menuGoHome(_:)), Shortcut("h", [.command, .shift]))),
        .command(Command("go.root", "Computer Root", #selector(M.menuGoRoot(_:)))),
        .command(Command("go.gitRoot", "Git Repository Root", #selector(M.menuGoToGitRoot(_:)))),
        .command(Command("go.goToFolder", "Go to Folder…", #selector(M.menuGoToFolder(_:)), Shortcut("g", [.command, .shift]))),
        .separator,
        // Adds or removes, so it can be pressed without first working out
        // whether the folder is already pinned.
        .command(Command("go.addFavourite", "Add to Sidebar", #selector(M.menuAddFavourite(_:)),
                         Shortcut("l", [.command, .shift]))),
        .separator,
        .command(Command("go.saveWorkspace", "Save Workspace…", #selector(M.menuSaveWorkspace(_:)), Shortcut("s", [.command, .shift]))),
        .command(Command("go.manageWorkspaces", "Manage Workspaces…", #selector(M.menuManageWorkspaces(_:)))),
    ])
}

extension Notification.Name {
    static let soquelShortcutsChanged = Notification.Name("app.soquel.shortcutsChanged")
}

extension PathFormat {
    /// Stable identifier for persistence, independent of the display title.
    var id: String {
        switch self {
        case .absolute: return "absolute"
        case .fileURL: return "fileURL"
        case .filename: return "filename"
        case .filenameNoExtension: return "filenameNoExtension"
        case .parentDirectory: return "parentDirectory"
        case .shellEscaped: return "shellEscaped"
        }
    }
}
