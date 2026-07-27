import AppKit

/// Ready-made colour sets, as a starting point for editing.
///
/// There is one theme file — `theme.json` — and these write into it. An earlier
/// design had a second format, `.soquel-theme`, with its own folder, its own
/// import and export, and a stored name recorded beside the file. Two places
/// claiming to hold the same truth is how a hand edit gets reverted on the next
/// launch, and every bug in that area came from the pair disagreeing.
///
/// A preset is not a mode you are in. Applying one writes its colours to
/// theme.json and stops being involved; editing them afterwards is editing your
/// own theme, not diverging from a preset.
struct ThemePreset: Equatable {
    let name: String
    let about: String
    let light: [String: String]
    let dark: [String: String]
}

enum ThemePresets {
    /// Applies a preset's colours, keeping the background image.
    ///
    /// The background is chosen separately from the colours, so picking a
    /// palette must not throw away the picture behind the file list.
    static func apply(_ preset: ThemePreset) {
        Theme.apply(ThemeConfig(light: preset.light, dark: preset.dark,
                                background: Theme.config.background))
    }

    /// The preset the current colours came from, if they still match one.
    ///
    /// Derived by comparison rather than remembered, so it cannot disagree with
    /// the file. Edit one value and no preset matches, which is the truth.
    static var current: ThemePreset? {
        all.first { $0.light == Theme.config.light && $0.dark == Theme.config.dark }
    }

    static let all: [ThemePreset] = [
        ThemePreset(
            name: "Soquel",
            about: "The colours the application ships with.",
            light: [:], dark: [:]
        ),
        ThemePreset(
            name: "Paper",
            about: "Warm and low contrast, for reading rather than scanning.",
            light: [
                "accent": "#8A5A2B", "selectionFill": "#8A5A2B", "selectionFillInactive": "#E0D7C8",
                "rowAlternate": "#F7F2E8", "chrome": "#FAF6EE", "hairline": "#E2D8C6",
                "danger": "#A33B2A",
            ],
            dark: [
                "accent": "#D8A76A", "selectionFill": "#8A5A2B", "selectionFillInactive": "#3A332A",
                "rowAlternate": "#22201C", "chrome": "#1B1916", "hairline": "#332E26",
                "danger": "#D4705C",
            ]
        ),
        ThemePreset(
            name: "Slate",
            about: "Grey and blue, closer to the system's own.",
            light: [
                "accent": "#2F6FC4", "selectionFill": "#2F6FC4", "selectionFillInactive": "#D6DCE3",
                "rowAlternate": "#F4F6F8", "chrome": "#FBFCFD", "hairline": "#DDE4EA",
                "danger": "#C0392B",
            ],
            dark: [
                "accent": "#6EA3E8", "selectionFill": "#2F6FC4", "selectionFillInactive": "#2A323B",
                "rowAlternate": "#171B20", "chrome": "#12161A", "hairline": "#232A32",
                "danger": "#E06C5C",
            ]
        ),
        ThemePreset(
            name: "Terminal",
            about: "Green on near-black, for people who never left.",
            light: [
                "accent": "#1F7A3D", "selectionFill": "#1F7A3D", "selectionFillInactive": "#D5E6D9",
                "rowAlternate": "#F2F7F3", "chrome": "#FFFFFF", "hairline": "#D9E3DB",
                "danger": "#B03030",
            ],
            dark: [
                "accent": "#3DDC7F", "selectionFill": "#1F7A3D", "selectionFillInactive": "#1E2A22",
                "rowAlternate": "#0F1512", "chrome": "#0A0F0C", "hairline": "#1C2A20",
                "danger": "#FF6B5B",
            ]
        ),
        ThemePreset(
            name: "Sakura",
            about: "Pink throughout. Pairs with a photograph behind the list.",
            light: [
                "accent": "#D6407F", "selectionFill": "#E85D9B", "selectionFillInactive": "#F7CFE1",
                "rowAlternate": "#FDE6F0", "chrome": "#FFF0F6", "hairline": "#F3BDD5",
                "danger": "#D63054",
            ],
            dark: [
                "accent": "#FF8FC4", "selectionFill": "#C43D77", "selectionFillInactive": "#452030",
                "rowAlternate": "#301724", "chrome": "#26121A", "hairline": "#4C2434",
                "danger": "#FF6F8E",
            ]
        ),
    ]
}
