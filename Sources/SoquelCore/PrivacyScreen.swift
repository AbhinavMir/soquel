import AppKit

extension Notification.Name {
    /// Posted when the screen-sharing setting is toggled, so every window
    /// already on screen picks it up rather than only the next one.
    static let soquelScreenSharingChanged = Notification.Name("app.soquel.screenSharingChanged")
}

/// Keeps the application's windows out of screen sharing and recording.
///
/// A file manager shows what a screen share should not: client names in the
/// sidebar, a folder of patient records, the name of a key file. macOS can
/// leave a window out of any capture — it stays on the screen in front of the
/// person using it and is simply absent from what everyone else sees — and
/// that is a truer answer than blurring names one by one, because it covers
/// the parts nothing thought to blur.
enum PrivacyScreen {
    static var isOn: Bool {
        get { Prefs.hideFromScreenSharing }
        set {
            Prefs.hideFromScreenSharing = newValue
            applyToAllWindows()
            NotificationCenter.default.post(name: .soquelScreenSharingChanged, object: nil)
        }
    }

    /// Applied to a window as it is built, and again whenever the setting
    /// changes. A window created while the setting is on must not appear in a
    /// capture for the moment before anything gets round to telling it.
    static func apply(to window: NSWindow?) {
        window?.sharingType = isOn ? .none : .readOnly
    }

    static func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }

    /// What the menu item says. The state it describes is the one in force,
    /// not the one the click would bring about.
    static var menuTitle: String { "Hide from Screen Sharing" }
}
