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
            lastBackgroundStamp = backgroundStamp(for: config)
            NotificationCenter.default.post(name: .soquelThemeChanged, object: nil)
            return nil
        } catch {
            // Logged here as well as returned, because not every caller shows
            // the result — and a hand-edit typo that silently discards the
            // whole theme at launch looks like the theme simply vanished.
            Log.error(.app, "theme.json did not parse: \(error.localizedDescription)")
            return error
        }
    }

    /// The background in force, or `.none`.
    static var background: BackgroundConfig { config.background ?? .none }

    static var windowOpacity: CGFloat { config.effectiveWindowOpacity }

    static func setWindowOpacity(_ value: Double) {
        var updated = config
        updated.windowOpacity = value
        apply(updated)
    }

    static func setBackground(_ background: BackgroundConfig) {
        var updated = config
        updated.background = background
        // apply() empties the image cache when the picture's file changed.
        // The image-opacity slider also arrives here once per tick of a
        // drag, and its edits leave the file alone, so they must keep the
        // cached decode rather than force one per tick.
        apply(updated)
    }

    /// Applies an edited config and writes it, for the settings colour wells.
    ///
    /// Returns the write error so the caller can say the edit did not stick:
    /// the window still repaints from memory either way, which is exactly what
    /// makes a swallowed failure invisible until the next launch reverts it.
    @discardableResult
    static func apply(_ newConfig: ThemeConfig) -> Error? {
        config = newConfig
        invalidateImagesIfStale()
        var failure: Error?
        do {
            try ThemeConfig.write(newConfig)
        } catch {
            Log.error(.app, "could not write theme.json: \(error.localizedDescription)")
            failure = error
        }
        noteOwnWrite()
        NotificationCenter.default.post(name: .soquelThemeChanged, object: nil)
        return failure
    }

    // MARK: - Background image staleness

    /// The background image file as the cache last saw it: its URL plus the
    /// modification date and size the file had on disk at that moment.
    private struct BackgroundStamp: Equatable {
        var url: URL
        var modified: Date?
        var size: UInt64?
    }

    private static var lastBackgroundStamp: BackgroundStamp?

    private static func backgroundStamp(for config: ThemeConfig) -> BackgroundStamp? {
        guard let url = config.background?.imageURL else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return BackgroundStamp(
            url: url,
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.uint64Value
        )
    }

    /// Empties the image cache only when the picture itself changed.
    ///
    /// The cache keys on the URL alone, and reinstalling an updated theme
    /// writes new bytes to the same path, so the old picture would survive
    /// until relaunch if the URL were trusted on its own. But apply() also
    /// runs on every tick of the opacity slider and the colour wells, and
    /// emptying the cache there made every pane re-read and re-decode the
    /// photo once per mouse tick. Comparing a stamp of the file costs one
    /// stat per apply and tells the two cases apart.
    private static func invalidateImagesIfStale() {
        let stamp = backgroundStamp(for: config)
        guard stamp != lastBackgroundStamp else { return }
        BackgroundImageCache.shared.invalidate()
        lastBackgroundStamp = stamp
    }

    // MARK: - Watching the file

    /// What the file held when we last looked, so events for the directory's
    /// other files — settings.json is written constantly — do not trigger a
    /// theme reload and a full redraw.
    private static var lastSeenData: Data?
    private static var watcher: DispatchSourceFileSystemObject?

    /// Watches theme.json, so an edit from another editor redraws the window
    /// — and so the settings controls write on top of the file's current
    /// content instead of a stale launch-time cache. Without this, touching
    /// any appearance control after a hand edit silently erased the edit.
    static func startWatching() {
        guard watcher == nil else { return }
        let directory = ThemeConfig.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        lastSeenData = try? Data(contentsOf: ThemeConfig.fileURL)
        // The directory, not the file: an atomic save from a text editor
        // replaces the file, and a handle would point at the dead inode.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            let data = try? Data(contentsOf: ThemeConfig.fileURL)
            guard data != lastSeenData else { return }
            lastSeenData = data
            reload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Called after the app's own writes, so the watcher does not read back
    /// what was just written and reload it as an outside edit.
    private static func noteOwnWrite() {
        lastSeenData = try? Data(contentsOf: ThemeConfig.fileURL)
    }

    /// Back to the shipped colours.
    static func reset() throws {
        try ThemeConfig.removeFile()
        config = .empty
        noteOwnWrite()
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
        let url = try ThemeConfig.writeTemplate(background: config.background) { slot, isDark in
            resolved(slot, dark: isDark)
        }
        noteOwnWrite()
        return url
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
    static var style: ChromeStyle { config.effectiveStyle }
    static var selectionCornerRadius: CGFloat { style.cornerRadius }
    static var selectionInset: CGFloat { style.selectionInset }
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
    /// Set when the file carries a tag. Finder stopped colouring the whole row
    /// and colours a dot instead, which is a named reason people still pay for
    /// Path Finder.
    var tagTint: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let tagTint, !isSelected {
            // Faint: the row still has to be readable, and a saturated fill
            // behind body text is not.
            tagTint.withAlphaComponent(0.16).setFill()
            dirtyRect.fill()
            return
        }
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
        let fill = isFocusedRow ? Theme.selectionFill : Theme.selectionFillInactive

        // A classic selection is a square block across the whole row. Insetting
        // and rounding it is the modern look and undoes the effect entirely.
        guard Theme.style != .bevelled else {
            fill.setFill()
            bounds.fill()
            return
        }

        let rect = bounds.insetBy(dx: Theme.selectionInset, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Theme.selectionCornerRadius,
            yRadius: Theme.selectionCornerRadius
        )
        fill.setFill()
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

    /// Laid out by hand. Every visible cell used to carry Auto Layout
    /// constraints, and a table redraw resolved them through the window's
    /// whole constraint engine — a hundred rows deep on the main thread for
    /// each scroll tick. The cell is an icon and a label; two frames do it.
    static let iconSide: CGFloat = 16
    static let iconGap: CGFloat = 5
    static let trailingInset: CGFloat = 2

    override func layout() {
        super.layout()
        let bounds = self.bounds
        var textX: CGFloat = 0
        if let imageView {
            imageView.frame = NSRect(
                x: 0, y: (bounds.height - Self.iconSide) / 2,
                width: Self.iconSide, height: Self.iconSide
            )
            textX = Self.iconSide + Self.iconGap
        }
        if let textField {
            let height = textField.intrinsicContentSize.height
            textField.frame = NSRect(
                x: textX, y: (bounds.height - height) / 2,
                width: max(0, bounds.width - textX - Self.trailingInset), height: height
            )
        }
    }
}

/// The 3D edge that made a nineties interface look pressable.
///
/// A raised edge is light along the top and left and dark along the bottom and
/// right; a sunken one is the reverse. That is the whole trick — there is no
/// gradient, no shadow and no blur in it.
enum Bevel {
    case raised
    case sunken

    /// Drawn a pixel at a time rather than as a stroked path, because a
    /// half-pixel stroke on a Retina display gives a soft grey line and the
    /// point of this is that it is hard.
    func draw(in rect: NSRect) {
        let light = NSColor.white
        let dark = NSColor(white: 0.35, alpha: 1)
        let topLeft = self == .raised ? light : dark
        let bottomRight = self == .raised ? dark : light

        topLeft.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()

        bottomRight.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
}
