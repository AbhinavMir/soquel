import AppKit

extension Notification.Name {
    /// Posted after the theme file is reloaded or reset. Views that cache a
    /// resolved colour (anything touching CGColor) must refresh on this.
    static let soquelThemeChanged = Notification.Name("app.soquel.themeChanged")
}

/// The application's visual identity.
///
/// Colours are declared once here and resolved per appearance, so light and
/// dark are designed rather than inverted. The accent is deliberately not the
/// system accent: a file manager is read for hours, and a deep teal separates
/// selection from the blue that every other Mac app uses for it.
///
/// Every colour can be overridden from `~/Library/Application Support/Soquel/theme.json`.
/// The dynamic providers below read the current config at draw time, so a
/// reload takes effect without rebuilding any view.
enum Theme {
    // MARK: - User overrides

    /// Overrides currently in force. Assigned by `reload()`; settable directly
    /// so tests can exercise resolution without touching the filesystem.
    static var config = ThemeConfig.empty

    /// Reads the theme file. Returns the error rather than throwing so the
    /// caller can show it; a bad file leaves the previous colours in place.
    @discardableResult
    static func reload() -> Error? {
        do {
            config = try ThemeConfig.load()
            BackgroundImageCache.shared.invalidate()
            NotificationCenter.default.post(name: .soquelThemeChanged, object: nil)
            return nil
        } catch {
            return error
        }
    }

    /// The background in force, or `.none`.
    static var background: BackgroundConfig { config.background ?? .none }

    static func setBackground(_ background: BackgroundConfig) {
        var updated = config
        updated.background = background
        BackgroundImageCache.shared.invalidate()
        apply(updated)
    }

    /// Applies an edited config and writes it, for the settings colour wells.
    ///
    /// Editing a colour makes these no longer the preset's colours, so the
    /// recorded theme name is cleared. `ThemeLibrary.apply` sets the name after
    /// calling this, which is what keeps applying a preset showing its name.
    static func apply(_ newConfig: ThemeConfig) {
        config = newConfig
        try? ThemeConfig.write(newConfig)
        ThemeLibrary.currentName = ""
        NotificationCenter.default.post(name: .soquelThemeChanged, object: nil)
    }

    /// Back to the shipped colours. Clears the theme name too, so a reset is
    /// not undone by a preset being re-applied.
    static func reset() throws {
        try ThemeConfig.removeFile()
        config = .empty
        ThemeLibrary.currentName = ""
        NotificationCenter.default.post(name: .soquelThemeChanged, object: nil)
    }

    /// Writes a template containing every slot at the value actually in force,
    /// and keeps the configured background.
    ///
    /// This runs when the user asks to see the file. Writing built-in colours
    /// here would silently discard whatever they had set — the file is meant to
    /// show them their theme, not replace it.
    @discardableResult
    static func writeTemplate() throws -> URL {
        try ThemeConfig.writeTemplate(background: config.background) { slot, isDark in
            resolved(slot, dark: isDark)
        }
    }

    // MARK: - Built-in palette

    /// The colour a slot has before any theme touches it.
    static func builtIn(_ slot: ThemeConfig.Slot, dark: Bool) -> NSColor {
        switch slot {
        case .accent:
            return dark
                ? NSColor(srgbRed: 0.400, green: 0.612, blue: 1.000, alpha: 1)   // #6699FF
                : NSColor(srgbRed: 0.000, green: 0.153, blue: 0.502, alpha: 1)   // #002780
        case .selectionFill:
            // Solid, not translucent. A tinted wash over a light row leaves
            // dark text on a light background — technically "selected" and
            // genuinely hard to read. Windows 95 got this right: fill the row
            // and flip the text to white.
            return dark
                ? NSColor(srgbRed: 0.180, green: 0.353, blue: 0.780, alpha: 1)   // #2E5AC7
                : NSColor(srgbRed: 0.000, green: 0.153, blue: 0.502, alpha: 1)   // #002780
        case .selectionFillInactive:
            // A pane you are not in: solid grey, text stays its normal colour.
            return dark
                ? NSColor(srgbRed: 0.290, green: 0.290, blue: 0.310, alpha: 1)
                : NSColor(srgbRed: 0.792, green: 0.792, blue: 0.808, alpha: 1)
        case .rowAlternate:
            return dark
                ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.022)
                : NSColor(srgbRed: 0.102, green: 0.400, blue: 0.412, alpha: 0.028)
        case .chrome:
            return dark
                ? NSColor(srgbRed: 0.125, green: 0.137, blue: 0.137, alpha: 1)
                : NSColor(srgbRed: 0.965, green: 0.970, blue: 0.970, alpha: 1)
        case .hairline:
            return dark
                ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.12)
                : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.10)
        case .danger:
            return dark
                ? NSColor(srgbRed: 0.898, green: 0.408, blue: 0.361, alpha: 1)
                : NSColor(srgbRed: 0.647, green: 0.180, blue: 0.145, alpha: 1)
        }
    }

    /// The value actually used: the user's override when it parses, otherwise
    /// the designed default.
    static func resolved(_ slot: ThemeConfig.Slot, dark: Bool) -> NSColor {
        config.color(for: slot, dark: dark) ?? builtIn(slot, dark: dark)
    }

    // MARK: - Colours

    static let accent = slotColor(.accent)
    static let selectionFill = slotColor(.selectionFill)
    static let selectionFillInactive = slotColor(.selectionFillInactive)
    static let rowAlternate = slotColor(.rowAlternate)
    static let chrome = slotColor(.chrome)
    static let hairline = slotColor(.hairline)
    static let danger = slotColor(.danger)

    private static func slotColor(_ slot: ThemeConfig.Slot) -> NSColor {
        NSColor(name: nil) { appearance in
            resolved(slot, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }

    // MARK: - Type

    /// Filenames: the system face, which handles every script and ligature a
    /// filename can contain.
    static let rowName = NSFont.systemFont(ofSize: 12.5)

    /// Sizes and dates: monospaced digits so columns of numbers line up.
    static let rowNumeric = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

    /// Kind and other prose columns.
    static let rowSecondary = NSFont.systemFont(ofSize: 11.5)

    /// Paths are structure, not prose — they get a real monospaced face.
    static let path = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static let pathCurrent = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    static let sectionLabel = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    static let status = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // MARK: - Metrics

    static let rowHeight: CGFloat = 21
    static let selectionCornerRadius: CGFloat = 5
    static let selectionInset: CGFloat = 4
    static let focusBarHeight: CGFloat = 2
}

/// Container view that reports light/dark switches, so layer-backed chrome can
/// re-resolve the CGColors it cached.
final class ThemedContainerView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Draws the themed selection and alternating background instead of the system
/// slab highlight.
final class FileRowView: NSTableRowView {
    var isAlternateRow = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isAlternateRow, !isSelected else { return }
        Theme.rowAlternate.setFill()
        dirtyRect.fill()
    }

    /// True when the row is filled dark enough that its text must invert.
    var wantsInvertedText: Bool { isSelected && isFocusedRow }

    private var isFocusedRow: Bool {
        isEmphasized || (window?.isKeyWindow == true && isSelectedAndActive)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Theme.selectionInset, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Theme.selectionCornerRadius,
            yRadius: Theme.selectionCornerRadius
        )
        (isFocusedRow ? Theme.selectionFill : Theme.selectionFillInactive).setFill()
        path.fill()
    }

    /// Tells every cell in the row whether to invert, whenever selection or
    /// focus changes.
    private func refreshCellText() {
        for case let cell as FileCellView in subviews {
            cell.isOnFilledSelection = wantsInvertedText
        }
    }

    override var isSelected: Bool {
        didSet { refreshCellText(); needsDisplay = true }
    }

    override var isEmphasized: Bool {
        didSet { refreshCellText(); needsDisplay = true }
    }

    /// True when this row belongs to the table that currently has focus.
    private var isSelectedAndActive: Bool {
        guard let table = superview as? NSTableView else { return false }
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === table || responder.isDescendant(of: table)
    }
}


/// A cell that knows when it is sitting on a filled selection, so its text can
/// invert instead of staying dark on dark.
final class FileCellView: NSTableCellView {
    /// The colour to use when the row is not selected.
    var restingTextColor: NSColor = .labelColor {
        didSet { applyTextColor() }
    }

    var isOnFilledSelection = false {
        didSet { applyTextColor() }
    }

    private func applyTextColor() {
        textField?.textColor = isOnFilledSelection ? .white : restingTextColor
    }
}
