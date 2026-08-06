import Foundation

/// What is in Settings, so it can be searched rather than hunted for.
///
/// Five panes is already more than anyone remembers the layout of, and the
/// thing people know is what they want to change, not which tab it lives
/// under.
enum SettingsIndex {
    struct Entry: Equatable {
        /// The pane's identifier, for switching to it.
        let pane: String
        let paneTitle: String
        let title: String
        /// Words somebody would type instead of the title. "Transparent" for
        /// opacity, "font" for the colours, "wallpaper" for the background.
        let keywords: String

        var subtitle: String { paneTitle }
    }

    static let all: [Entry] = [
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Highlights",
              keywords: "accent colour color focus bar path git"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Selected row",
              keywords: "selection colour color highlight blue"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Every other row",
              keywords: "banding stripe zebra alternating colour color"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Toolbars and tabs",
              keywords: "chrome background grey gray colour color surface"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Lines and borders",
              keywords: "hairline divider separator rule colour color"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Warnings and errors",
              keywords: "danger red error failure colour color"),
        Entry(pane: "appearance", paneTitle: "Appearance", title: "Dark mode colours",
              keywords: "dark light appearance mode night"),

        Entry(pane: "window", paneTitle: "Window", title: "Window opacity",
              keywords: "transparent translucent see through alpha faded ghost"),
        Entry(pane: "window", paneTitle: "Window", title: "Background image",
              keywords: "wallpaper picture photo behind image backdrop"),
        Entry(pane: "window", paneTitle: "Window", title: "Image opacity and fit",
              keywords: "wallpaper picture faded stretch fill tile scale"),

        Entry(pane: "themes", paneTitle: "Themes", title: "Ready-made themes",
              keywords: "preset windows 95 platinum air paper slate terminal sakura retro"),
        Entry(pane: "themes", paneTitle: "Themes", title: "Edges",
              keywords: "rounded bevelled square corners classic retro chrome shape"),
        Entry(pane: "themes", paneTitle: "Themes", title: "Install a theme",
              keywords: "gist github repository repo share download import"),
        Entry(pane: "themes", paneTitle: "Themes", title: "Share your theme",
              keywords: "copy export gist repository publish"),

        Entry(pane: "keyboard", paneTitle: "Keyboard", title: "Shortcuts",
              keywords: "keys keybinding hotkey remap rebind command"),
        Entry(pane: "keyboard", paneTitle: "Keyboard", title: "vi-style keys",
              keywords: "vim hjkl keyboard first modal navigation"),

        Entry(pane: "applications", paneTitle: "Applications", title: "What opens each file",
              keywords: "default app open with handler association duti extension"),
        Entry(pane: "applications", paneTitle: "Applications", title: "Add a file kind",
              keywords: "extension type new custom duti"),
        Entry(pane: "applications", paneTitle: "Applications", title: "Ask before slow apps",
              keywords: "xcode android studio warn confirm launch heavy"),

        Entry(pane: "updates", paneTitle: "Updates", title: "Tell me about new versions",
              keywords: "update check github release version upgrade network"),
    ]

    /// Entries matching every word typed.
    ///
    /// Every word rather than any: "dark colour" should narrow to the colours
    /// rather than widening to everything with either word in it.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        return all.filter { entry in
            let haystack = "\(entry.title) \(entry.paneTitle) \(entry.keywords)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The panes a search touches, in the order they appear.
    static func panes(matching query: String) -> [String] {
        var seen: [String] = []
        for entry in search(query) where !seen.contains(entry.pane) {
            seen.append(entry.pane)
        }
        return seen
    }
}
