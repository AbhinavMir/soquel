import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [MainWindowController] = []
    private var settingsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Log.startHousekeeping()
        Log.info(.app, "Soquel starting")
        // Settings come from settings.json; anything already in the defaults
        // database is carried over the first time.
        Settings.migrateFromUserDefaults(.standard, keys: Prefs.keys + ToolbarCatalogue.migratedKeys)
        Settings.startWatching()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .soquelSettingsChanged, object: nil, queue: .main
        ) { _ in
            // An outside edit to the file redraws everything that reads it.
            SidebarStore.reloadFromDisk()
            NotificationCenter.default.post(name: .soquelToolbarChanged, object: nil)
            NotificationCenter.default.post(name: .soquelShortcutsChanged, object: nil)
            NotificationCenter.default.post(name: .soquelSidebarChanged, object: nil)
            for controller in (NSApp.delegate as? AppDelegate)?.windowControllers ?? [] {
                controller.refreshAllPanes()
            }
        }
        // Apply user colour overrides before the first window is built.
        // theme.json is the only thing consulted: nothing else stores colours,
        // so nothing can disagree with it or overwrite it on the way up.
        Theme.reload()
        let menu = makeMainMenu()
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.compactMap(\.submenu).first { $0.title == "Window" }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .soquelShortcutsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let rebuilt = self.makeMainMenu()
            NSApp.mainMenu = rebuilt
            NSApp.windowsMenu = rebuilt.items.compactMap(\.submenu).first { $0.title == "Window" }
        }

        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // First launch only. A file manager that cannot read Desktop or
        // Documents looks broken rather than unpermitted, so it is worth one
        // window saying what to grant and why.
        WelcomeWindowController.showIfFirstLaunch()

        // Opens a panel straight away, for screenshots and for reproducing a
        // bug without describing six clicks first.
        if let panel = ProcessInfo.processInfo.environment["SOQUEL_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.windowControllers.first?.openPanelNamed(panel)
            }
        }

        if ProcessInfo.processInfo.environment["SOQUEL_DEBUG_WINDOW"] != nil {
            let w = windowControllers.first?.window
            FileHandle.standardError.write("""
            debug: windows=\(NSApp.windows.count) \
            frame=\(w?.frame ?? .zero) visible=\(w?.isVisible ?? false) \
            screens=\(NSScreen.screens.count) content=\(w?.contentView?.frame ?? .zero)

            """.data(using: .utf8)!)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Opens folders handed over by the system.
    ///
    /// This is what makes Soquel usable as the handler for folders: without it,
    /// double-clicking one in Finder, or dropping it on the Dock icon, would
    /// launch the application at the home directory and lose the folder. A file
    /// rather than a folder is passed back to whatever normally opens it, since
    /// Soquel is a file manager and not an editor of anything.
    public func application(_ application: NSApplication, open urls: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { continue }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }

        for (index, url) in folders.enumerated() {
            // The first folder goes into the window that already exists — at
            // launch that is the empty one made by applicationDidFinishLaunching
            // — and any others get their own.
            if index > 0 || windowControllers.isEmpty { newWindow(nil) }
            windowControllers.last?.open(folder: url)
        }
        for url in files { NSWorkspace.shared.open(url) }
        if !folders.isEmpty { NSApp.activate(ignoringOtherApps: true) }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "Soquel quitting")
        for controller in windowControllers { controller.saveSession() }
        // Writes are coalesced, so the last quarter second of changes — which
        // includes the session just saved above — is still only in memory.
        Settings.writeNow()
    }

    @objc func showWelcome(_ sender: Any?) {
        WelcomeWindowController.shared.show()
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = MainWindowController()
        windowControllers.append(controller)
        controller.showWindow(nil)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            self?.windowControllers.removeAll { $0 === controller }
        }
    }

    // MARK: - Menu

    /// Builds the full main menu from `CommandRegistry`, so a shortcut shown
    /// in the palette or the settings pane is always the one that fires.
    /// Returned rather than installed so tests can inspect it.
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Soquel")
        appMenu.addItem(withTitle: "About Soquel", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Set Up Permissions…", action: #selector(showWelcome(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(MainWindowController.menuSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Soquel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Soquel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        for section in CommandRegistry.sections {
            let item = NSMenuItem()
            let menu = NSMenu(title: section.title)
            for entry in section.entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .command(let command):
                    menu.addItem(menuItem(for: command))
                }
            }
            // Open in Terminal / Editor also offer every installed app.
            if section.title == "Go" {
                let workspaces = NSMenuItem(title: "Open Workspace", action: nil, keyEquivalent: "")
                workspaces.submenu = MainWindowController.workspaceMenu()
                menu.addItem(workspaces)
            }
            if section.title == "View" {
                let columns = NSMenuItem(title: "Extra Columns", action: nil, keyEquivalent: "")
                columns.submenu = MainWindowController.metadataColumnMenu()
                menu.addItem(.separator())
                menu.addItem(columns)
            }
            if section.title == "File" {
                if let index = menu.items.firstIndex(where: { $0.title == "Open in Terminal" }) {
                    let picker = NSMenuItem(title: "Open in Terminal With", action: nil, keyEquivalent: "")
                    picker.submenu = MainWindowController.terminalPickerPlaceholder()
                    menu.insertItem(picker, at: index + 1)
                }
                if let index = menu.items.firstIndex(where: { $0.title == "Open in Editor" }) {
                    let picker = NSMenuItem(title: "Open in Editor With", action: nil, keyEquivalent: "")
                    picker.submenu = MainWindowController.editorPickerPlaceholder()
                    menu.insertItem(picker, at: index + 1)
                }
            }
            item.submenu = menu
            main.addItem(item)
        }

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    private func menuItem(for command: Command) -> NSMenuItem {
        let shortcut = command.shortcut
        let item = NSMenuItem(
            title: command.title,
            action: command.selector,
            keyEquivalent: shortcut?.key ?? ""
        )
        if let shortcut { item.keyEquivalentModifierMask = shortcut.flags }
        // Pane-focus commands carry an index as a tag; copy-path variants carry
        // the format name as the represented object.
        if let represented = command.representedObject {
            if let index = Int(represented) { item.tag = index } else { item.representedObject = represented }
        }
        // Only the app delegate's own commands target it directly; everything
        // else travels the responder chain to the focused window.
        if command.selector == #selector(newWindow(_:)) { item.target = self }
        return item
    }

    @discardableResult
    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        menu.addItem(item)
        return item
    }
}
