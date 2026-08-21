import AppKit
import CoreServices

/// Standing in for Finder, as far as macOS allows.
///
/// The obvious route does not work: `public.folder` cannot be reassigned.
/// `LSSetDefaultRoleHandlerForContentType` returns −50 for it under every role
/// mask, from a signed application bundle as readily as from a loose binary,
/// while the same call for `public.plain-text` or `public.volume` returns 0.
/// See docs/RESEARCH-replacing-finder.md for the measurements.
///
/// What works instead is later in the sequence. Finder's launchd job restarts
/// it only after an unsuccessful exit, so a Finder that is asked to quit stays
/// quit, and every route back — the Dock's tile, a reveal from another
/// application, `open` — starts by *launching* Finder, which is observable in
/// 27 ms and needs no permission at all.
///
/// So the Dock tile is not removed. It is allowed to do its job, and Soquel
/// takes the hand-off.
enum FinderTakeover {
    static let finderID = "com.apple.finder"

    // MARK: - Settings

    /// Quit Finder whenever it starts, and open Soquel instead.
    static var catchesFinder: Bool {
        get { Settings.object(forKey: "catchFinderLaunch") as? Bool ?? false }
        set {
            Settings.set(newValue, forKey: "catchFinderLaunch")
            newValue ? start() : stop()
        }
    }

    /// Ask Finder where it was going before quitting it. Needs Automation
    /// permission; without it the folder cannot be known and Soquel opens the
    /// last folder instead of the right one.
    static var followsFinder: Bool {
        get { Settings.object(forKey: "followFinderTarget") as? Bool ?? false }
        set { Settings.set(newValue, forKey: "followFinderTarget") }
    }

    /// Mounting a disk opens Soquel. This one is an ordinary default-handler
    /// change, because `public.volume` is not refused the way `public.folder` is.
    static var opensVolumes: Bool {
        get { defaultHandler(for: "public.volume") == Bundle.main.bundleIdentifier }
        set {
            let target = newValue ? (Bundle.main.bundleIdentifier ?? "") : finderID
            LSSetDefaultRoleHandlerForContentType("public.volume" as CFString, .all, target as CFString)
        }
    }

    static func defaultHandler(for uti: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?.takeRetainedValue() as String?
    }

    /// Whether the folder handler could be taken even if we wanted it.
    ///
    /// Kept as a function rather than a constant so the settings pane states a
    /// measured fact rather than a belief. If a future macOS allows it, this
    /// starts returning true and nothing else has to change.
    static func canClaimFolders() -> Bool {
        defaultHandler(for: "public.folder") == Bundle.main.bundleIdentifier
    }

    // MARK: - Watching

    private static var observer: NSObjectProtocol?

    static var isRunning: Bool { observer != nil }

    static func startIfEnabled() { if catchesFinder { start() } }

    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == finderID
            else { return }
            handle(app)
        }
        Log.info(.app, "watching for Finder")
    }

    static func stop() {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
        Log.info(.app, "stopped watching for Finder")
    }

    /// Finder has started. Find out where it was going, show that, and let it go.
    private static func handle(_ finder: NSRunningApplication) {
        Log.info(.app, "Finder started (pid \(finder.processIdentifier))")

        guard followsFinder else {
            // Nothing to ask, so nothing to wait for.
            finish(finder, at: nil)
            return
        }
        // Never on the main thread. An unanswered Automation prompt blocks the
        // caller outright — during testing it froze the watcher and every
        // other AppleEvent on the machine until it was answered.
        askFinderWhereItWent { path in
            finish(finder, at: path)
        }
    }

    private static func finish(_ finder: NSRunningApplication, at path: String?) {
        if let path {
            // Shown here rather than posted and forgotten. This used to post a
            // notification that nothing observed, so the switch did nothing at
            // all — and it is the switch that asks for permission to control
            // Finder, so it was asking for that permission and buying nothing.
            show(URL(fileURLWithPath: path))
        }
        // terminate() rather than a quit AppleEvent: it needs no permission,
        // and it is a clean exit, which is what keeps launchd from restarting
        // Finder a second later.
        if !finder.terminate() {
            Log.info(.app, "Finder refused to quit")
        }
    }

    /// Opens what Finder was going to open, in whichever window is in front.
    static func show(_ url: URL) {
        let controller = NSApp.keyWindow?.windowController as? MainWindowController
            ?? NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
        guard let controller else {
            // No window to show it in — one is made, because the whole point
            // is that Finder does not get to be the one that opens.
            NSWorkspace.shared.open(url)
            return
        }
        controller.reveal(url)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Asking Finder

    /// How long to wait before deciding the answer is not coming.
    static let askTimeout: TimeInterval = 1.5

    /// The selection first, because a reveal sets it, then the front window's
    /// folder, which is what a plain Dock click gives.
    static let script = """
    tell application "Finder"
        try
            return POSIX path of (item 1 of (get selection) as alias)
        end try
        try
            return POSIX path of ((target of front window) as alias)
        end try
        return ""
    end tell
    """

    static func askFinderWhereItWent(_ completion: @escaping (String?) -> Void) {
        var answered = false
        let lock = NSLock()
        func answer(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            guard !answered else { return }
            answered = true
            DispatchQueue.main.async { completion(value) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                Log.info(.app, "could not ask Finder: \(error[NSAppleScript.errorMessage] ?? "unknown")")
                answer(nil)
                return
            }
            let path = result?.stringValue ?? ""
            answer(path.isEmpty ? nil : path)
        }

        // A prompt that is never answered must not hold Finder open for ever.
        DispatchQueue.global().asyncAfter(deadline: .now() + askTimeout) { answer(nil) }
    }

    // MARK: - Permission

    /// Whether Soquel may drive Finder, asked without putting up a prompt.
    static func hasAutomationPermission() -> Bool {
        var target = AEAddressDesc()
        let id = finderID
        _ = id.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, false
        ) == noErr
    }

    /// Puts the prompt up deliberately, from a button, rather than letting it
    /// appear in the middle of something else.
    static func requestAutomationPermission(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var target = AEAddressDesc()
            let id = finderID
            _ = id.withCString { pointer in
                AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
            }
            let status = AEDeterminePermissionToAutomateTarget(
                &target, typeWildCard, typeWildCard, true
            )
            AEDisposeDesc(&target)
            DispatchQueue.main.async { completion(status == noErr) }
        }
    }

    // MARK: - The desktop

    static var hidesDesktopIcons: Bool {
        get {
            UserDefaults(suiteName: "com.apple.finder")?
                .object(forKey: "CreateDesktop") as? Bool == false
        }
        set {
            let defaults = UserDefaults(suiteName: "com.apple.finder")
            newValue ? defaults?.set(false, forKey: "CreateDesktop")
                     : defaults?.removeObject(forKey: "CreateDesktop")
            defaults?.synchronize()
            // Finder only reads this at start, so it has to be restarted. An
            // unclean kill is right here: launchd brings it back, and it comes
            // back reading the new setting.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Finder"]
            try? task.run()
        }
    }

    // MARK: - Undo

    /// Puts everything back the way macOS ships it, in one call.
    static func giveBackToFinder() {
        catchesFinder = false
        followsFinder = false
        opensVolumes = false
        hidesDesktopIcons = false
        Log.info(.app, "handed everything back to Finder")
    }
}

extension Notification.Name {
    /// A path Finder was asked to show, which Soquel is showing instead.
    static let soquelRevealRequested = Notification.Name("soquelRevealRequested")
}
