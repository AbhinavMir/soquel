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

    static func bundleID(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// The application that would open these files, when they all agree on one.
    /// Returns nil for a mixed selection, where there is no single answer to
    /// ask about.
    static func applicationThatWouldOpen(_ urls: [URL]) -> URL? {
        let apps = urls.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        guard let first = apps.first, apps.count == urls.count else { return nil }
        guard apps.allSatisfy({ $0.standardizedFileURL == first.standardizedFileURL }) else { return nil }
        return first
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
