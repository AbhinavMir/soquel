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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
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

        tabs.addTabViewItem(appearance)
        tabs.addTabViewItem(themes)
        tabs.addTabViewItem(keyboard)
        tabs.addTabViewItem(applications)

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
    private var wells: [(slot: ThemeConfig.Slot, dark: Bool, well: NSColorWell)] = []

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
            grid.addRow(with: [label(title(for: slot)), lightWell, darkWell])
        }

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
        addSubview(backgroundBox)
        addSubview(buttons)
        addSubview(note)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            backgroundBox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
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

    private func title(for slot: ThemeConfig.Slot) -> String {
        switch slot {
        case .accent: return "Accent"
        case .selectionFill: return "Selection"
        case .selectionFillInactive: return "Selection (unfocused pane)"
        case .rowAlternate: return "Alternating row"
        case .chrome: return "Toolbars"
        case .hairline: return "Dividers"
        case .danger: return "Destructive actions"
        }
    }

    private func label(_ text: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: weight)
        return field
    }

    private func well(for slot: ThemeConfig.Slot, dark: Bool) -> NSColorWell {
        let well = NSColorWell()
        well.color = Theme.resolved(slot, dark: dark)
        well.target = self
        well.action = #selector(wellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 54).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        wells.append((slot, dark, well))
        return well
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard let entry = wells.first(where: { $0.well === sender }) else { return }
        var config = Theme.config
        if entry.dark {
            config.dark[entry.slot.rawValue] = sender.color.hexString
        } else {
            config.light[entry.slot.rawValue] = sender.color.hexString
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
