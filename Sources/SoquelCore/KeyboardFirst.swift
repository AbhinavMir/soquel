import AppKit

/// The vi-style key preset.
///
/// These are handled in the file list rather than bound as menu shortcuts. A
/// menu item with `j` as its key equivalent would swallow the letter in every
/// text field in the application, which is why the preset could not simply be
/// a second keymap.
enum KeyboardFirst {
    enum Action: Equatable {
        case moveDown
        case moveUp
        case moveToTop
        case moveToBottom
        case halfPageDown
        case halfPageUp
        case goToParent
        case openSelection
        case goBack
        case goForward
        case extendDown
        case extendUp
        case beginFilter
        case clearSelection
        /// The first `g` of `gg`: nothing happens until the second one.
        case awaitingSecondG
    }

    /// Resolves one keypress.
    ///
    /// `pendingG` is true when the previous keypress was a bare `g`, which is
    /// the only two-key sequence in the preset.
    static func action(
        forCharacters characters: String,
        modifiers: NSEvent.ModifierFlags,
        pendingG: Bool
    ) -> Action? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        if flags == [.control] {
            switch characters {
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            default: return nil
            }
        }

        // Shift is part of the key for G and J/K, so it is allowed through;
        // Command and Option are not, and belong to the menu shortcuts.
        guard flags.isEmpty || flags == [.shift] else { return nil }

        if pendingG {
            // Only `gg` continues the sequence; anything else starts over and
            // is handled on its own terms.
            if characters == "g" { return .moveToTop }
        }

        switch characters {
        case "j": return .moveDown
        case "k": return .moveUp
        case "J": return .extendDown
        case "K": return .extendUp
        case "g": return .awaitingSecondG
        case "G": return .moveToBottom
        case "h": return .goToParent
        case "l": return .openSelection
        case "H": return .goBack
        case "L": return .goForward
        case "/": return .beginFilter
        default: return nil
        }
    }

    /// The two-key sequence is abandoned after this long, so a stray `g` does
    /// not silently change what the next keypress means.
    static let sequenceTimeout: TimeInterval = 1.0

    /// Every binding, for the settings window and the documentation.
    static let bindings: [(keys: String, description: String)] = [
        ("j / k", "Down / up"),
        ("J / K", "Extend the selection down / up"),
        ("g g", "First item"),
        ("G", "Last item"),
        ("⌃d / ⌃u", "Half a page down / up"),
        ("h", "Enclosing folder"),
        ("l", "Open the selection"),
        ("H / L", "Back / forward"),
        ("/", "Filter this folder"),
    ]
}
