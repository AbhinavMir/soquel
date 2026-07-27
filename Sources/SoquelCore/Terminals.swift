import AppKit

/// A terminal or editor Soquel can hand the current folder to.
struct ExternalApp: Equatable {
    let name: String
    let bundleID: String
    /// Where it usually lives, used when Launch Services cannot resolve the ID.
    let fallbackPath: String

    var url: URL? {
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return byID }
        let path = fallbackPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    var isInstalled: Bool { url != nil }
}

enum ExternalApps {
    /// Terminals worth offering, in the order they are shown. Detection is by
    /// bundle identifier so a terminal installed anywhere is still found.
    static let terminals: [ExternalApp] = [
        ExternalApp(name: "Terminal", bundleID: "com.apple.Terminal",
                    fallbackPath: "/System/Applications/Utilities/Terminal.app"),
        ExternalApp(name: "iTerm2", bundleID: "com.googlecode.iterm2",
                    fallbackPath: "/Applications/iTerm.app"),
        ExternalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty",
                    fallbackPath: "/Applications/Ghostty.app"),
        ExternalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm",
                    fallbackPath: "/Applications/WezTerm.app"),
        ExternalApp(name: "Alacritty", bundleID: "org.alacritty",
                    fallbackPath: "/Applications/Alacritty.app"),
        ExternalApp(name: "Kitty", bundleID: "net.kovidgoyal.kitty",
                    fallbackPath: "/Applications/kitty.app"),
        ExternalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable",
                    fallbackPath: "/Applications/Warp.app"),
        ExternalApp(name: "Hyper", bundleID: "co.zeit.hyper",
                    fallbackPath: "/Applications/Hyper.app"),
    ]

    static let editors: [ExternalApp] = [
        ExternalApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
                    fallbackPath: "/Applications/Visual Studio Code.app"),
        ExternalApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92",
                    fallbackPath: "/Applications/Cursor.app"),
        ExternalApp(name: "Zed", bundleID: "dev.zed.Zed",
                    fallbackPath: "/Applications/Zed.app"),
        ExternalApp(name: "Sublime Text", bundleID: "com.sublimetext.4",
                    fallbackPath: "/Applications/Sublime Text.app"),
        ExternalApp(name: "Nova", bundleID: "com.panic.Nova",
                    fallbackPath: "/Applications/Nova.app"),
        ExternalApp(name: "Xcode", bundleID: "com.apple.dt.Xcode",
                    fallbackPath: "/Applications/Xcode.app"),
        ExternalApp(name: "BBEdit", bundleID: "com.barebones.bbedit",
                    fallbackPath: "/Applications/BBEdit.app"),
    ]

    static var installedTerminals: [ExternalApp] { terminals.filter(\.isInstalled) }
    static var installedEditors: [ExternalApp] { editors.filter(\.isInstalled) }

    /// The terminal to use: the user's choice when it is still installed,
    /// otherwise the first one that is. Never silently falls back to something
    /// the user did not pick without saying so in the status bar.
    static func preferredTerminal() -> ExternalApp? {
        if let chosen = Prefs.terminalBundleID,
           let match = terminals.first(where: { $0.bundleID == chosen }),
           match.isInstalled {
            return match
        }
        return installedTerminals.first
    }

    static func preferredEditor() -> ExternalApp? {
        if let chosen = Prefs.editorBundleID,
           let match = editors.first(where: { $0.bundleID == chosen }),
           match.isInstalled {
            return match
        }
        return installedEditors.first
    }

    /// Opens `url` in `app`. The folder is passed as a launch argument rather
    /// than through a shell string, so a filename can never be read as a
    /// command.
    static func open(_ urls: [URL], in app: ExternalApp, completion: @escaping (Error?) -> Void) {
        guard let appURL = app.url else {
            completion(SoquelError.appNotFound(app.name))
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
