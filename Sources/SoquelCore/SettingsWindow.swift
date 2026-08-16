import AppKit

/// A view whose origin is the top-left corner, so a form laid out inside a
/// scroll view starts at the top the way a reader expects.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The document view behind a settings pane. Besides putting the origin at
/// the top, it keeps the pane's wrapping labels wrapping at the width layout
/// gives them instead of the width of their whole text.
///
/// A label that wraps still reports its entire text on one line as its
/// intrinsic width, and its default resistance to being squeezed (750) beats
/// the priority a window uses to hold its size (500). Every constraint
/// between the label and the window frame is required, so the label won:
/// selecting Themes pushed the window from 660pt to 906pt, Updates to 1039pt,
/// and nothing brought it back. A pane can pin `preferredMaxLayoutWidth` to
/// a number, but that number does not follow the window. Here every wrapping
/// label the pane built yields to the window instead, and its
/// `preferredMaxLayoutWidth` tracks the width it is laid out at, so the
/// height follows the wrap rather than staying at one line.
final class SettingsPaneHost: FlippedView {
    private var observers: [NSObjectProtocol] = []

    /// Labels that already carry a `preferredMaxLayoutWidth` are left as
    /// their pane set them; they have a finite width and cannot push.
    func adopt(wrappingLabelsIn pane: NSView) {
        for label in Self.wrappingLabels(in: pane) {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: label, queue: nil
            ) { [weak label] _ in
                guard let label else { return }
                // The width is fixed by the label's own pins, so once it is
                // recorded the frame only changes in height and this settles.
                let width = label.frame.width
                guard width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 else { return }
                label.preferredMaxLayoutWidth = width
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private static func wrappingLabels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        for sub in view.subviews {
            if let field = sub as? NSTextField, !field.isEditable,
               field.preferredMaxLayoutWidth == 0,
               field.lineBreakMode == .byWordWrapping || field.lineBreakMode == .byCharWrapping {
                found.append(field)
            }
            found += wrappingLabels(in: sub)
        }
        return found
    }
}

/// A window that closes on Escape and on ⌘W.
///
/// AppKit only routes Escape to a button wired as the cancel button, and a
/// settings window has no Cancel — there is nothing to cancel, the changes are
/// already applied. So the key is handled here instead. ⌘W belongs to Close
/// Tab in the menu bar, whose target lives on the main window controller, so
/// with this window key it did nothing at all; key equivalents reach the key
/// window before the menu, which is where it becomes Close.
final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Preferences window. Appearance edits the colour slots with a real colour
/// well, Keyboard remaps any command's shortcut, and Applications chooses what
/// opens each kind of file.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    /// Built here rather than in an `init()`. A `convenience init()` on an
    /// NSWindowController subclass collides with the inherited designated
    /// `init()`, and `SettingsWindowController()` silently resolved to the
    /// inherited one — so the window was never created and ⌘, did nothing.
    static let shared: SettingsWindowController = {
        let window = EscapableWindow(
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
        // Centring unconditionally threw away the origin the autosave name
        // restored; centre only when no frame has been saved yet.
        if !window.setFrameUsingName("SoquelSettings") { window.center() }
        return controller
    }()

    private var tabs: NSTabView!

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var search: NSSearchField!
    private var results: NSTableView!
    private var resultsScroll: NSScrollView!
    /// Sits over the empty results list when a search finds nothing. Without
    /// it the list vanished and the pane underneath showed, which read as the
    /// search having done nothing at all.
    private var noMatches: NSTextField!
    private var matches: [SettingsIndex.Entry] = []

    fileprivate var matchCount: Int { matches.count }
    fileprivate func match(at row: Int) -> SettingsIndex.Entry? {
        matches.indices.contains(row) ? matches[row] : nil
    }

    @objc private func searchChanged() {
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = SettingsIndex.search(search.stringValue)
        // The list only covers the tabs while something has been typed, so
        // an empty box leaves the pane you were on exactly where it was. A
        // term that matches nothing keeps the list up, empty, with the
        // message on top of it.
        resultsScroll.isHidden = term.isEmpty
        noMatches.isHidden = term.isEmpty || !matches.isEmpty
        noMatches.stringValue = "Nothing matched “\(term)”"
        results.reloadData()
    }

    /// Escape in the search box: a filled box clears and shows the panes
    /// again; an empty one closes the window. Without this the field editor
    /// swallowed the key and Escape appeared to do nothing at all.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty {
            window?.close()
        } else {
            search.stringValue = ""
            searchChanged()
        }
        return true
    }

    @objc private func resultClicked() {
        guard let entry = match(at: results.selectedRow) else { return }
        show(pane: entry.pane)
        search.stringValue = ""
        searchChanged()
    }

    fileprivate func build() {
        tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let appearance = NSTabViewItem(identifier: "appearance")
        appearance.label = "Appearance"
        appearance.view = Self.paneContainer(AppearanceSettingsView())

        let keyboard = NSTabViewItem(identifier: "keyboard")
        keyboard.label = "Keyboard"
        keyboard.view = Self.paneContainer(KeyboardSettingsView())

        let themes = NSTabViewItem(identifier: "themes")
        themes.label = "Themes"
        themes.view = Self.paneContainer(ThemeSettingsView())

        let applications = NSTabViewItem(identifier: "applications")
        applications.label = "Applications"
        applications.view = Self.paneContainer(ApplicationSettingsView())

        let windowPane = NSTabViewItem(identifier: "window")
        windowPane.label = "Window"
        windowPane.view = Self.paneContainer(WindowSettingsView())

        let updates = NSTabViewItem(identifier: "updates")
        updates.label = "Updates"
        updates.view = Self.paneContainer(UpdateSettingsView())

        tabs.addTabViewItem(appearance)
        tabs.addTabViewItem(windowPane)
        tabs.addTabViewItem(themes)
        tabs.addTabViewItem(keyboard)
        tabs.addTabViewItem(applications)
        tabs.addTabViewItem(updates)

        search = NSSearchField()
        search.placeholderString = "Search settings — try “transparent” or “default app”"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        results = NSTableView()
        results.headerView = nil
        results.rowHeight = 30
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(resultClicked)
        let resultColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        resultColumn.resizingMask = .autoresizingMask
        results.addTableColumn(resultColumn)

        resultsScroll = NSScrollView()
        resultsScroll.documentView = results
        resultsScroll.hasVerticalScroller = true
        resultsScroll.borderType = .bezelBorder
        resultsScroll.isHidden = true
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false

        noMatches = NSTextField(labelWithString: "")
        noMatches.font = .systemFont(ofSize: 12)
        noMatches.textColor = .secondaryLabelColor
        noMatches.alignment = .center
        noMatches.lineBreakMode = .byTruncatingMiddle
        // A long term is truncated in the middle rather than allowed to push
        // the window wider than the list it sits in.
        noMatches.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noMatches.isHidden = true
        noMatches.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(search)
        root.addSubview(tabs)
        root.addSubview(resultsScroll)
        // Added after the list so it draws on top of it.
        root.addSubview(noMatches)
        NSLayoutConstraint.activate([
            noMatches.centerXAnchor.constraint(equalTo: resultsScroll.centerXAnchor),
            noMatches.centerYAnchor.constraint(equalTo: resultsScroll.centerYAnchor),
            noMatches.leadingAnchor.constraint(greaterThanOrEqualTo: resultsScroll.leadingAnchor, constant: 12),
            noMatches.trailingAnchor.constraint(lessThanOrEqualTo: resultsScroll.trailingAnchor, constant: -12),

            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            resultsScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            resultsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            resultsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            resultsScroll.heightAnchor.constraint(equalToConstant: 200),

            tabs.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    /// Wraps a settings pane so it can never make the window wider.
    ///
    /// A tab view takes its width from the widest pane in it, so one label
    /// that wraps without a width to wrap inside pushed the whole window out
    /// every time the Themes tab was selected. Pinning the pane to the scroll
    /// view's width gives every label something finite to lay out against,
    /// the host makes the labels accept that width (see `SettingsPaneHost`),
    /// and a pane taller than the window scrolls rather than being cut off.
    static func paneContainer(_ pane: NSView) -> NSView {
        pane.translatesAutoresizingMaskIntoConstraints = false

        // The pane goes inside a flipped host, not straight into the scroll
        // view. An NSScrollView's document space grows upward from the
        // bottom; a pane shorter than the clip was pinned to the top of the
        // clip's unflipped coordinate space, which is the bottom of what is
        // on screen, so every pane except the tallest drew below the visible
        // area and could not be scrolled to. Flipping the host puts y=0 at
        // the top, where a settings form starts.
        let host = SettingsPaneHost()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.adopt(wrappingLabelsIn: pane)
        sizeInnerScrollViews(in: pane)
        host.addSubview(pane)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = host

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            // Width only. Pinning the bottom too would stop it scrolling.
            host.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return scroll
    }

    /// How tall a table inside a pane is made. Large enough to show a dozen
    /// rows, small enough that the pane around it still fits the window at the
    /// size it opens at.
    private static let innerScrollHeight: CGFloat = 420

    /// Gives every scroll view a pane puts inside itself a real height.
    ///
    /// The Keyboard, Applications and Themes panes each hold a table in a
    /// scroll view, and the pane is in turn the document of the scroll view
    /// built above. A scroll view has no intrinsic height, and a document view
    /// is free to be any height at all, so nothing in that chain said how tall
    /// the inner one should be and it settled at zero: the Keyboard table
    /// measured 607x2794 inside a clip of 605x0, and the pane drew its column
    /// headers on top of the label that belongs under the table. The height is
    /// applied here, where every pane passes through, because two of those
    /// panes cannot be reached from this file.
    ///
    /// The constraint is not required, so a pane that does size its own scroll
    /// view keeps the size it asked for and no conflict is logged.
    private static func sizeInnerScrollViews(in pane: NSView) {
        for scroll in innerScrollViews(in: pane) {
            let height = scroll.heightAnchor.constraint(equalToConstant: innerScrollHeight)
            height.priority = .defaultHigh
            height.isActive = true
        }
    }

    /// The scroll views a pane lays out itself. A scroll view found this way is
    /// not descended into: what it scrolls is its own business, and only the
    /// one the pane positions needs to be given a height. A view still carrying
    /// its autoresizing mask is left alone, because a constraint cannot be
    /// added to it without breaking the layout it already has.
    private static func innerScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView {
                if !scroll.translatesAutoresizingMaskIntoConstraints { found.append(scroll) }
            } else {
                found += innerScrollViews(in: sub)
            }
        }
        return found
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
    private var saveStatus: NSTextField!
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        build()
        // The wells are seeded once, but the Themes pane and hand edits to
        // theme.json change the colours out from under them. The preview
        // already follows this notification; the swatches have to as well,
        // or a click on a stale one opens the panel on the old colour and
        // the first drag tick writes that old colour back into the slot.
        // Re-assigning an unchanged colour during a drag only redraws, so
        // no feedback loop forms.
        observer = NotificationCenter.default.addObserver(
            forName: .soquelThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for entry in self.wells {
                entry.well.color = Theme.resolved(entry.slot, dark: entry.dark)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

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


        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetAll))
        let openFile = NSButton(title: "Reveal theme.json", target: self, action: #selector(revealFile))
        let note = label("Changes apply immediately. The same values live in theme.json, which you can version or share.")
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        // Where a failed write of theme.json is reported. The window still
        // repaints from memory when the write fails, so without a visible
        // message the edit looks applied and silently reverts at relaunch.
        saveStatus = label("")
        saveStatus.textColor = Theme.danger
        saveStatus.lineBreakMode = .byTruncatingTail
        saveStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [reset, openFile, saveStatus])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false

        addSubview(grid)
        addSubview(previewCaption)
        addSubview(preview)
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

            buttons.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            // The last row pins the bottom, like every other pane: the scroll
            // container takes the document height from these constraints, and
            // without this one a short window could never scroll to the note.
            note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
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
        // The wells repaint from memory whether or not the write succeeds,
        // so the failure has to be said out loud here or the edit silently
        // reverts at the next launch. Cleared on success so a message left
        // over from a transient failure does not outlive it.
        if let error = Theme.apply(config) {
            saveStatus.stringValue = "Could not save: \(error.localizedDescription)"
        } else {
            saveStatus.stringValue = ""
        }
    }

    @objc private func resetAll() {
        try? Theme.reset()
        for entry in wells {
            entry.well.color = Theme.resolved(entry.slot, dark: entry.dark)
        }
    }

    @objc private func revealFile() {
        _ = try? Theme.writeTemplate()
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
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: conflictLabel.topAnchor, constant: -8),

            conflictLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            conflictLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            conflictLabel.bottomAnchor.constraint(equalTo: resetAll.topAnchor, constant: -10),

            resetAll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
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

        let recorder = ShortcutRecorderView(command: command, report: { [weak self] in
            self?.conflictLabel.stringValue = $0
        }, onCommit: { [weak self] in
            self?.commands = CommandRegistry.all
            self?.table.reloadData()
        })
        return recorder
    }
}

/// Click to arm, then press a combination. Reports conflicts rather than
/// silently creating two commands with the same shortcut.
final class ShortcutRecorderView: NSView {
    private let command: Command
    private let report: (String) -> Void
    /// Runs only when a binding actually changed. Kept apart from `report`:
    /// committing reloads the table, and a reload tears this recorder down —
    /// so a rejection that reloaded would end the very recording session its
    /// message invites you to retry.
    private let onCommit: () -> Void
    private var recording = false
    private var label: NSTextField!

    init(command: Command, report: @escaping (String) -> Void, onCommit: @escaping () -> Void) {
        self.command = command
        self.report = report
        self.onCommit = onCommit
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
            onCommit()
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
        onCommit()
    }

    /// Command-key events travel the window's performKeyEquivalent chain
    /// before any keyDown, and the default NSView implementation lets the
    /// menu take them — so ⌘N opened a window instead of being recorded, and
    /// anything bound to a menu item could never be captured at all. While
    /// recording, the event is claimed and given the keyDown handling here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
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


extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { matchCount }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = match(at: row) else { return nil }
        let cell = NSTableCellView()

        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        // The pane is on the row, so a result says where it is going to take
        // you before you click it.
        let pane = NSTextField(labelWithString: entry.subtitle)
        pane.font = .systemFont(ofSize: 11)
        pane.textColor = .secondaryLabelColor
        pane.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(title)
        cell.addSubview(pane)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pane.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            pane.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: pane.leadingAnchor, constant: -10),
        ])
        return cell
    }
}
