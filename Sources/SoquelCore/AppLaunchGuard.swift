import AppKit

/// Asks before launching something that takes a long time to start.
///
/// Double-clicking a `.xcodeproj` by accident costs a minute of watching a
/// splash screen and a few gigabytes of memory. The prompt is only for
/// applications that are actually slow to start; asking before TextEdit would
/// be worse than not asking at all.
enum AppLaunchGuard {
    /// Applications heavy enough to be worth a question. Bundle identifiers
    /// rather than names, because names are localised and change.
    static let knownHeavy: Set<String> = [
        "com.apple.dt.Xcode",
        "com.google.android.studio",
        "com.unity3d.UnityEditor5.x",
        "com.unity3d.unityhub",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.jetbrains.goland",
        "com.jetbrains.datagrip",
        "com.jetbrains.toolbox",
        "com.adobe.Photoshop",
        "com.adobe.Illustrator",
        "com.adobe.AfterEffects",
        "com.adobe.PremierePro",
        "com.adobe.InDesign",
        "com.apple.FinalCut",
        "com.apple.motion",
        "com.apple.logic10",
        "com.microsoft.VSCode",
        "com.docker.docker",
        "org.blenderfoundation.blender",
        "com.figma.Desktop",
        "com.parallels.desktop.console",
        "org.virtualbox.app.VirtualBox",
        "com.vmware.fusion",
    ]

    private static let allowKey = "launchWithoutAsking"
    private static let enabledKey = "confirmHeavyLaunches"

    /// On by default. The whole point is to catch an accidental double-click,
    /// which is not something you opt into.
    static var isEnabled: Bool {
        get { Settings.object(forKey: enabledKey) as? Bool ?? true }
        set { Settings.set(newValue, forKey: enabledKey) }
    }

    /// Bundle identifiers the user has said not to ask about again.
    static var allowed: Set<String> {
        Set(Settings.stringArray(forKey: allowKey) ?? [])
    }

    static func alwaysAllow(_ bundleID: String) {
        var list = allowed
        list.insert(bundleID)
        Settings.set(Array(list).sorted(), forKey: allowKey)
        Log.info(.app, "Will no longer ask before launching \(bundleID)")
    }

    static func forgetAllowances() {
        Settings.set([String](), forKey: allowKey)
    }

    /// Adds an application to the heavy list, so a user's own slow application
    /// gets the same prompt as Xcode.
    static var userHeavy: Set<String> {
        Set(Settings.stringArray(forKey: "heavyApplications") ?? [])
    }

    static func markHeavy(_ bundleID: String) {
        var list = userHeavy
        list.insert(bundleID)
        Settings.set(Array(list).sorted(), forKey: "heavyApplications")
    }

    /// Whether opening this application warrants a question.
    static func shouldAsk(about bundleID: String?) -> Bool {
        guard isEnabled, let bundleID else { return false }
        guard knownHeavy.contains(bundleID) || userHeavy.contains(bundleID) else { return false }
        return !allowed.contains(bundleID)
    }

    /// Bundle identifiers by application path, and default applications by
    /// filename extension.
    ///
    /// Both answers come from Launch Services, which reads them off disk:
    /// about 6 ms for the first query and a further 1.5 ms to open the
    /// application's Info.plist. That was paid once per file on the main
    /// thread every time anything was opened, so a selection of twenty files
    /// spent a visible fraction of a second deciding something that depends
    /// only on the extension. Both are cached, and the caches are dropped
    /// when the set of installed applications changes.
    private static var bundleIDByApp: [String: String] = [:]
    private static var appByExtension: [String: URL] = [:]
    private static let cacheLock = NSLock()

    /// Launch Services answers change when applications are installed or
    /// removed, which is what this notification reports.
    static func startWatchingInstalledApplications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { _ in clearCaches() }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.LaunchServices.applicationRegistered"),
            object: nil, queue: .main
        ) { _ in clearCaches() }
    }

    static func clearCaches() {
        cacheLock.lock()
        bundleIDByApp.removeAll()
        appByExtension.removeAll()
        cacheLock.unlock()
    }

    static func bundleID(of app: URL) -> String? {
        let key = app.standardizedFileURL.path
        cacheLock.lock()
        if let hit = bundleIDByApp[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let identifier = Bundle(url: app)?.bundleIdentifier else { return nil }
        cacheLock.lock()
        bundleIDByApp[key] = identifier
        cacheLock.unlock()
        return identifier
    }

    /// The default application for one file, by extension where that decides
    /// it. A package or a file with no extension is asked about directly:
    /// its answer depends on the item itself, so caching it under a shared
    /// key would hand one item's application to another.
    static func application(toOpen url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !url.hasDirectoryPath else {
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        cacheLock.lock()
        if let hit = appByExtension[ext] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        cacheLock.lock()
        appByExtension[ext] = app
        cacheLock.unlock()
        return app
    }

    /// The application that would open these files, when they all agree on one.
    /// Returns nil for a mixed selection, where there is no single answer to
    /// ask about.
    static func applicationThatWouldOpen(_ urls: [URL]) -> URL? {
        let apps = urls.compactMap { application(toOpen: $0) }
        guard let first = apps.first, apps.count == urls.count else { return nil }
        guard apps.allSatisfy({ $0.standardizedFileURL == first.standardizedFileURL }) else { return nil }
        return first
    }

    /// Opens files without waiting for the applications to start.
    ///
    /// `NSWorkspace.open(_:)` returns only once Launch Services has taken the
    /// request, so opening from the main thread held the file list still
    /// while another application woke up. This hands the work over and
    /// returns; `whenFailed` names anything that could not be opened.
    static func open(_ urls: [URL], whenFailed: @escaping (URL) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        for url in urls {
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async { whenFailed(url) }
            }
        }
    }

    enum Answer {
        case open
        case openAndStopAsking
        case cancel
    }

    /// Asks, and returns what to do. Split out from the presentation so the
    /// decision can be tested without putting a window on screen.
    static func answer(for response: NSApplication.ModalResponse) -> Answer {
        switch response {
        case .alertFirstButtonReturn: return .open
        case .alertSecondButtonReturn: return .openAndStopAsking
        default: return .cancel
        }
    }

    /// Runs `open` once the user has agreed, or straight away when there is
    /// nothing to ask about.
    ///
    /// `app` is the application that will be launched; pass nil to look up
    /// whatever would open the files by default.
    static func confirm(
        opening urls: [URL],
        with app: URL?,
        in window: NSWindow?,
        open launch: @escaping () -> Void
    ) {
        // The guard being off is the common case and the cheapest answer:
        // decided before anything is asked of Launch Services, since the
        // lookup exists only to name the application in the question.
        guard isEnabled else {
            launch()
            return
        }
        let target = app ?? applicationThatWouldOpen(urls)
        let identifier = target.flatMap(bundleID(of:))

        guard shouldAsk(about: identifier), let target, let identifier else {
            launch()
            return
        }

        let name = FileManager.default.displayName(atPath: target.path)
        let alert = NSAlert()
        alert.messageText = "This will open \(name). Are you sure?"
        alert.informativeText = urls.count == 1
            ? "\(urls[0].lastPathComponent) opens in \(name), which is slow to start."
            : "\(urls.count) items open in \(name), which is slow to start."
        alert.icon = NSWorkspace.shared.icon(forFile: target.path)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Open, Don’t Ask Again")
        alert.addButton(withTitle: "Cancel")

        Log.info(.app, "Asking before launching \(identifier)")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch answer(for: response) {
            case .open:
                launch()
            case .openAndStopAsking:
                alwaysAllow(identifier)
                launch()
            case .cancel:
                Log.info(.app, "Cancelled launching \(identifier)")
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
