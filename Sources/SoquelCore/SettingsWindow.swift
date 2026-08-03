import AppKit

/// Preferences window. Appearance edits the colour slots with a real colour
/// well, Keyboard remaps any command's shortcut, and Applications chooses what
/// opens each kind of file.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Built here rather than in an `init()`. A `convenience init()` on an
    /// NSWindowController subclass collides with the inherited designated
    /// `init()`, and `SettingsWindowController()` silently resolved to the
    /// inherited one — so the window was never created and ⌘, did nothing.
    static let shared: SettingsWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soquel Settings"
        window.setFrameAutosaveName("SoquelSettings")
        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        controller.build()
        window.center()
        return controller
    }()

    private var tabs: NSTabView!

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func build() {
        tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let appearance = NSTabViewItem(identifier: "appearance")
        appearance.label = "Appearance"
        appearance.view = AppearanceSettingsView()

        let keyboard = NSTabViewItem(identifier: "keyboard")
        keyboard.label = "Keyboard"
        keyboard.view = KeyboardSettingsView()

        let themes = NSTabViewItem(identifier: "themes")
        themes.label = "Themes"
        themes.view = ThemeSettingsView()

        let applications = NSTabViewItem(identifier: "applications")
        applications.label = "Applications"
        applications.view = ApplicationSettingsView()

        let updates = NSTabViewItem(identifier: "updates")
        updates.label = "Updates"
        updates.view = UpdateSettingsView()

        tabs.addTabViewItem(appearance)
        tabs.addTabViewItem(themes)
        tabs.addTabViewItem(keyboard)
        tabs.addTabViewItem(applications)
        tabs.addTabViewItem(updates)

        let root = NSView()
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    /// Opens the window on a named pane, for `SOQUEL_OPEN=settings:applications`.
    func show(pane: String?) {
        show()
        guard let pane, let index = tabs.tabViewItems.firstIndex(where: {
            ($0.identifier as? String) == pane
        }) else { return }
        tabs.selectTabViewItem(at: index)
    }
}

// MARK: - Appearance

/// A colour well per slot, for light and dark, writing straight to theme.json.
final class AppearanceSettingsView: NSView {
    private var wells: [(slot: ThemeConfig.Slot, dark: Bool, well: ColourSwatchButton)] = []

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    fileprivate func build() {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 16

        let header = NSGridRow?.none
        _ = header
        grid.addRow(with: [
            label("Colour", weight: .semibold),
            label("Light", weight: .semibold),
            label("Dark", weight: .semibold),
        ])

        for slot in ThemeConfig.Slot.allCases {
            let lightWell = well(for: slot, dark: false)
            let darkWell = well(for: slot, dark: true)

            let name = label(Self.title(for: slot), weight: .medium)
            let detail = label(Self.explanation(for: slot))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 3
            detail.preferredMaxLayoutWidth = 300

            let text = NSStackView(views: [name, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            grid.addRow(with: [text, lightWell, darkWell])
        }

        let preview = ThemePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewCaption = label("A pane, drawn with these colours.")
        previewCaption.font = .systemFont(ofSize: 11)
        previewCaption.textColor = .secondaryLabelColor
        previewCaption.translatesAutoresizingMaskIntoConstraints = false

        let backgroundBox = buildBackgroundControls()

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetAll))
        let openFile = NSButton(title: "Reveal theme.json", target: self, action: #selector(revealFile))
        let note = label("Changes apply immediately. The same values live in theme.json, which you can version or share.")
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        let buttons = NSStackView(views: [reset, openFile])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false

        addSubview(grid)
        addSubview(previewCaption)
        addSubview(preview)
        addSubview(backgroundBox)
        addSubview(buttons)
        addSubview(note)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            previewCaption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            previewCaption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            preview.topAnchor.constraint(equalTo: previewCaption.bottomAnchor, constant: 5),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            preview.heightAnchor.constraint(equalToConstant: 108),

            backgroundBox.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 18),
            backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            buttons.topAnchor.constraint(equalTo: backgroundBox.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    // MARK: - Background image

    private var pathLabel: NSTextField!
    private var opacitySlider: NSSlider!
    private var opacityReadout: NSTextField!
    private var fitControl: NSPopUpButton!

    private func buildBackgroundControls() -> NSView {
        let config = Theme.background

        let heading = label("Background image", weight: .semibold)

        pathLabel = label(config.imageURL?.lastPathComponent ?? "None")
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseImage))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearImage))

        opacitySlider = NSSlider(value: config.opacity, minValue: 0, maxValue: 1,
                                 target: self, action: #selector(opacityChanged))
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        opacityReadout = label(Self.percent(config.opacity))
        opacityReadout.font = Theme.rowNumeric
        opacityReadout.textColor = .secondaryLabelColor
        opacityReadout.widthAnchor.constraint(equalToConstant: 44).isActive = true

        fitControl = NSPopUpButton()
        fitControl.addItems(withTitles: BackgroundFit.allCases.map(\.title))
        fitControl.selectItem(at: BackgroundFit.allCases.firstIndex(of: config.fit) ?? 0)
        fitControl.target = self
        fitControl.action = #selector(fitChanged)

        let row1 = NSStackView(views: [choose, clear, pathLabel])
        row1.orientation = .horizontal
        row1.spacing = 8

        let row2 = NSStackView(views: [label("Opacity"), opacitySlider, opacityReadout,
                                       label("Fit"), fitControl])
        row2.orientation = .horizontal
        row2.spacing = 8

        let stack = NSStackView(views: [heading, row1, row2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick an image to show behind the file list"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var background = Theme.background
        background.imagePath = url.path
        pathLabel.stringValue = url.lastPathComponent
        Theme.setBackground(background)
    }

    @objc private func clearImage() {
        var background = Theme.background
        background.imagePath = nil
        pathLabel.stringValue = "None"
        Theme.setBackground(background)
    }

    @objc private func opacityChanged() {
        var background = Theme.background
        background.opacity = opacitySlider.doubleValue
        opacityReadout.stringValue = Self.percent(background.opacity)
        Theme.setBackground(background)
    }

    @objc private func fitChanged() {
        var background = Theme.background
        let index = fitControl.indexOfSelectedItem
        guard BackgroundFit.allCases.indices.contains(index) else { return }
        background.fit = BackgroundFit.allCases[index]
        Theme.setBackground(background)
    }

    /// What the slot is called on screen. "Accent" and "chrome" are words for
    /// people who write user interfaces, not for people using one.
    static func title(for slot: ThemeConfig.Slot) -> String {
        switch slot {
        case .accent: return "Highlights"
        case .selectionFill: return "Selected row"
        case .selectionFillInactive: return "Selected row, other pane"
        case .rowAlternate: return "Every other row"
        case .chrome: return "Toolbars and tabs"
        case .hairline: return "Lines and borders"
        case .danger: return "Warnings and errors"
        }
    }

    /// Where the colour actually turns up, so the row can be understood
    /// without changing it and hunting for what moved.
    static func explanation(for slot: ThemeConfig.Slot) -> String {
        switch slot {
        case .accent:
            return "The bar above the pane you are in, the current folder in the path, "
                + "a toolbar button that is switched on, and a file Git says has changed."
        case .selectionFill:
            return "The file you have clicked, in the pane you are working in."
        case .selectionFillInactive:
            return "The file still selected in a pane you have moved away from, "
                + "and the fill behind the list/icon/column switch."
        case .rowAlternate:
            return "The faint banding down a long list, so a row is easy to follow across."
        case .chrome:
            return "The strip holding the toolbar buttons, the tab you are on, "
                + "and the middle of the disk map."
        case .hairline:
            return "The one-pixel rules between panes, around tabs and under headers."
        case .danger:
            return "A transfer that failed, a rename that cannot be applied, "
                + "a search that could not read something."
        }
    }

    private func label(_ text: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: weight)
        return field
    }

    private func well(for slot: ThemeConfig.Slot, dark: Bool) -> NSView {
        let swatch = ColourSwatchButton(
            color: Theme.resolved(slot, dark: dark), dark: dark
        ) { [weak self] colour in
            self?.store(colour, in: slot, dark: dark)
        }
        swatch.setAccessibilityLabel("\(Self.title(for: slot)), \(dark ? "dark" : "light")")
        wells.append((slot, dark, swatch))
        return swatch
    }

    private func store(_ colour: NSColor, in slot: ThemeConfig.Slot, dark: Bool) {
        var config = Theme.config
        if dark {
            config.dark[slot.rawValue] = colour.hexString
        } else {
            config.light[slot.rawValue] = colour.hexString
        }
        Theme.apply(config)
    }

    @objc private func resetAll() {
        try? Theme.reset()
        for entry in wells {
            entry.well.color = Theme.resolved(entry.slot, dark: entry.dark)
        }
        pathLabel.stringValue = "None"
        opacitySlider.doubleValue = BackgroundConfig.none.opacity
        opacityReadout.stringValue = Self.percent(BackgroundConfig.none.opacity)
        fitControl.selectItem(at: 0)
    }

    @objc private func revealFile() {
        try? Theme.writeTemplate()
        NSWorkspace.shared.activateFileViewerSelecting([ThemeConfig.fileURL])
    }
}

// MARK: - Keyboard

/// Every command with its current shortcut, remappable in place.
final class KeyboardSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var table: NSTableView!
    private var commands: [Command] = CommandRegistry.all
    private var conflictLabel: NSTextField!

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    fileprivate func build() {
        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        name.title = "Command"
        name.width = 300
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        key.title = "Shortcut"
        key.width = 160
        table.addTableColumn(name)
        table.addTableColumn(key)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        conflictLabel = NSTextField(labelWithString: "Click a shortcut, then press the keys you want. ⌫ clears it.")
        conflictLabel.font = Theme.status
        conflictLabel.textColor = .secondaryLabelColor
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false

        let resetAll = NSButton(title: "Reset All Shortcuts", target: self, action: #selector(resetAll))
        resetAll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(conflictLabel)
        addSubview(resetAll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: conflictLabel.topAnchor, constant: -8),

            conflictLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            conflictLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            conflictLabel.bottomAnchor.constraint(equalTo: resetAll.topAnchor, constant: -10),

            resetAll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            resetAll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    @objc private func resetAll() {
        CommandRegistry.resetAllShortcuts()
        commands = CommandRegistry.all
        table.reloadData()
        conflictLabel.stringValue = "All shortcuts reset to their defaults."
    }

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row), let tableColumn else { return nil }
        let command = commands[row]

        if tableColumn.identifier.rawValue == "command" {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: command.title)
            field.font = Theme.rowName
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            ])
            return cell
        }

        let recorder = ShortcutRecorderView(command: command) { [weak self] in
            self?.commands = CommandRegistry.all
            self?.table.reloadData()
            self?.conflictLabel.stringValue = $0
        }
        return recorder
    }
}

/// Click to arm, then press a combination. Reports conflicts rather than
/// silently creating two commands with the same shortcut.
final class ShortcutRecorderView: NSView {
    private let command: Command
    private let report: (String) -> Void
    private var recording = false
    private var label: NSTextField!

    init(command: Command, report: @escaping (String) -> Void) {
        self.command = command
        self.report = report
        super.init(frame: .zero)

        label = NSTextField(labelWithString: "")
        label.font = Theme.rowNumeric
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func refresh() {
        let current = CommandRegistry.shortcut(for: command)
        label.stringValue = recording ? "Press keys…" : (current?.display ?? "—")
        label.textColor = recording
            ? Theme.accent
            : (CommandRegistry.isRemapped(command) ? Theme.accent : .secondaryLabelColor)
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refresh()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }

        // Escape abandons, Delete unbinds.
        if event.keyCode == 53 {
            recording = false
            refresh()
            return
        }
        if event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            CommandRegistry.setShortcut(nil, for: command)
            recording = false
            refresh()
            report("\(command.title) has no shortcut.")
            return
        }

        guard let shortcut = Shortcut.from(event: event) else {
            report("Use at least one of ⌘, ⌥, or ⌃ — a bare key would fire while typing.")
            return
        }

        let clashes = CommandRegistry.conflicts(with: shortcut, excluding: command)
        guard clashes.isEmpty else {
            report("\(shortcut.display) is already \(clashes.map(\.title).joined(separator: ", ")).")
            return
        }

        CommandRegistry.setShortcut(shortcut, for: command)
        recording = false
        refresh()
        report("\(command.title) is now \(shortcut.display).")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard recording else { return }
        Theme.selectionFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
    }
}


/// Sits behind a colour well so a nearly transparent slot is seen against the
/// surface it will be drawn on, rather than against the well's own chequerboard.
final class SwatchBackingView: NSView {
    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        (dark ? NSColor.black : NSColor.white).setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

/// A mock file list, drawn with the colours as they are now.
///
/// The pane behind the Settings window is usually covered by it, so a change
/// used to mean closing Settings to find out what moved. This shows it in place.
final class ThemePreviewView: NSView {
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        observer = NotificationCenter.default.addObserver(
            forName: .soquelThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 108) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight: CGFloat = 20
        let toolbar: CGFloat = 24

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // The toolbar strip, with the accent bar above it.
        Theme.chrome.setFill()
        NSRect(x: 0, y: bounds.maxY - toolbar, width: bounds.width, height: toolbar).fill()
        Theme.accent.setFill()
        NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()

        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - toolbar, width: bounds.width, height: 1).fill()

        let names = ["Reports", "notes.txt", "budget.csv", "archive.zip"]
        for (index, name) in names.enumerated() {
            let y = bounds.maxY - toolbar - CGFloat(index + 1) * rowHeight
            let row = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)

            if index == 1 {
                Theme.selectionFill.setFill()
                row.insetBy(dx: 3, dy: 1).fill()
            } else if index == 3 {
                Theme.selectionFillInactive.setFill()
                row.insetBy(dx: 3, dy: 1).fill()
            } else if index % 2 == 1 {
                Theme.rowAlternate.setFill()
                row.fill()
            }

            let colour: NSColor
            if index == 1 {
                colour = .white
            } else if index == 2 {
                colour = Theme.danger
            } else if index == 0 {
                colour = Theme.accent
            } else {
                colour = .labelColor
            }
            let text = index == 2 ? "\(name)  could not be read" : name
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: colour,
            ]).draw(at: NSPoint(x: 10, y: y + 4))
        }
    }
}

/// A colour swatch that shows what the colour will actually look like.
///
/// NSColorWell draws a black-and-white diagonal for anything with alpha, which
/// is how AppKit says "this is transparent". Two of the slots are transparent
/// on purpose — the row banding is 2% white, the hairline 10% black — so the
/// control that is meant to show them showed a barber's pole instead. This
/// paints the colour over the surface it will really sit on.
final class ColourSwatchButton: NSView {
    /// The swatch the shared colour panel is currently editing.
    private(set) static weak var owner: ColourSwatchButton?

    var color: NSColor { didSet { needsDisplay = true } }
    /// Which page the colour lands on, so a faint one is judged against it.
    private let dark: Bool
    private let onChange: (NSColor) -> Void

    init(color: NSColor, dark: Bool, onChange: @escaping (NSColor) -> Void) {
        self.color = color
        self.dark = dark
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityRole(.colorWell)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)

        (dark ? NSColor.black : NSColor.white).setFill()
        path.fill()
        color.setFill()
        path.fill()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = color
        Self.owner = self
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        // The shared panel keeps talking to whichever swatch opened it last,
        // and it cannot be asked who that is. Tracking it here stops a stale
        // swatch quietly rewriting the slot the open one owns.
        guard ColourSwatchButton.owner === self else { return }
        color = sender.color
        onChange(sender.color)
    }

    override func accessibilityValue() -> Any? { color.hexString }
}
