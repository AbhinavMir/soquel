import AppKit

/// A button that can sit in the pane toolbar.
struct ToolbarAction {
    let id: String
    let title: String
    let symbol: String
    let selector: Selector
    /// Reads back the on/off state for toggles, so the button shows what is true.
    let isOn: (() -> Bool)?
    /// Drawn instead of `symbol` while the toggle is off. A tint change alone
    /// says "this button is dimmer than that one", which is not the same as
    /// saying what the button would do — an eye reads as "showing" whether or
    /// not anything is being shown. Where a symbol has an honest opposite, the
    /// two are drawn and the state is legible without hovering for a tooltip.
    let symbolWhenOff: String?
    /// Shown instead of `title` while the toggle is on. A button labelled
    /// "Show Hidden Files" that would in fact hide them is a lie in a tooltip.
    let titleWhenOn: String?
    /// Actions sharing a group are mutually exclusive and draw as one pill.
    let group: String?

    init(_ id: String, _ title: String, _ symbol: String, _ selector: Selector,
         isOn: (() -> Bool)? = nil, symbolWhenOff: String? = nil,
         titleWhenOn: String? = nil, group: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.selector = selector
        self.isOn = isOn
        self.symbolWhenOff = symbolWhenOff
        self.titleWhenOn = titleWhenOn
        self.group = group
    }

    /// The symbol to draw right now.
    var currentSymbol: String {
        guard let symbolWhenOff, isOn?() == false else { return symbol }
        return symbolWhenOff
    }

    /// The title to show right now.
    var currentTitle: String {
        guard let titleWhenOn, isOn?() == true else { return title }
        return titleWhenOn
    }

    /// The same action with its state read from somewhere else. The catalogue's
    /// toggles read the global settings, and a bar that knows better — a pane
    /// whose folder is in a view of its own — swaps that reading in.
    func withState(_ isOn: @escaping () -> Bool) -> ToolbarAction {
        ToolbarAction(id, title, symbol, selector, isOn: isOn, symbolWhenOff: symbolWhenOff,
                      titleWhenOn: titleWhenOn, group: group)
    }

    /// What the tooltip says: the title, then the key that does the same thing.
    ///
    /// A toolbar that never mentions the shortcut is a toolbar people keep
    /// reaching for. Matched on the selector, so a remapped key shows the new
    /// one rather than the shipped default.
    var tooltip: String {
        guard let shortcut = ToolbarCatalogue.shortcutDisplay(for: selector) else {
            return currentTitle
        }
        return "\(currentTitle)  \(shortcut)"
    }
}

/// Everything the toolbar can show, and which of them the user has chosen.
enum ToolbarCatalogue {
    private typealias M = MainWindowController

    static let all: [ToolbarAction] = [
        ToolbarAction("back", "Back", "chevron.left", #selector(M.menuGoBack(_:))),
        ToolbarAction("forward", "Forward", "chevron.right", #selector(M.menuGoForward(_:))),
        ToolbarAction("up", "Enclosing Folder", "chevron.up", #selector(M.menuGoUp(_:))),
        ToolbarAction("listView", "List View", "list.bullet", #selector(M.menuUseListView(_:)),
                      isOn: { Prefs.viewMode == .list }, group: "viewMode"),
        ToolbarAction("iconView", "Icon View", "square.grid.2x2", #selector(M.menuUseIconView(_:)),
                      isOn: { Prefs.viewMode == .icon }, group: "viewMode"),
        ToolbarAction("columnView", "Column View", "rectangle.split.3x1", #selector(M.menuUseColumnView(_:)),
                      isOn: { Prefs.viewMode == .column }, group: "viewMode"),
        ToolbarAction("hidden", "Show Hidden Files", "eye", #selector(M.menuToggleHidden(_:)),
                      isOn: { Prefs.showHiddenFiles }, symbolWhenOff: "eye.slash",
                      titleWhenOn: "Hide Hidden Files"),
        ToolbarAction("folderSizes", "Calculate Folder Sizes", "sum", #selector(M.menuToggleFolderSizes(_:)),
                      isOn: { Prefs.calculateFolderSizes }),
        ToolbarAction("gitStatus", "Show Git Status", "arrow.triangle.branch", #selector(M.menuToggleGitStatus(_:)),
                      isOn: { Prefs.showGitStatus }),
        ToolbarAction("inspector", "Show Preview", "sidebar.right", #selector(M.menuToggleInspector(_:)),
                      isOn: { Prefs.showInspector }),
        ToolbarAction("folderTree", "Show Folder Tree", "sidebar.leading", #selector(M.menuToggleFolderTree(_:)),
                      isOn: { Prefs.showFolderTree }),
        ToolbarAction("foldersFirst", "Folders First", "folder", #selector(M.menuToggleFoldersFirst(_:)),
                      isOn: { Prefs.foldersFirst }),
        ToolbarAction("find", "Find by Name", "magnifyingglass", #selector(M.menuFindByName(_:))),
        ToolbarAction("findContents", "Find in Contents", "doc.text.magnifyingglass", #selector(M.menuFindInContents(_:))),
        // Filled when the folder in front of you is already pinned, so the one
        // button reads as both "add" and "remove".
        ToolbarAction("favourite", "Add to Sidebar", "star", #selector(M.menuAddFavourite(_:)),
                      isOn: { M.favouriteIsOn() }),
        ToolbarAction("copyPath", "Copy Path", "doc.on.clipboard", #selector(M.menuCopyPathOfSelection(_:))),
        ToolbarAction("openWith", "Open With", "arrow.up.forward.square", #selector(M.menuOpenWith(_:))),
        ToolbarAction("newFolder", "New Folder", "folder.badge.plus", #selector(M.menuNewFolder(_:))),
        ToolbarAction("split", "Split Pane", "rectangle.split.2x1", #selector(M.menuSplitVertically(_:))),
        ToolbarAction("terminal", "Open in Terminal", "terminal", #selector(M.menuOpenInTerminal(_:))),
        ToolbarAction("editor", "Open in Editor", "chevron.left.forwardslash.chevron.right", #selector(M.menuOpenInEditor(_:))),
        ToolbarAction("reveal", "Reveal in Finder", "arrow.up.forward.app", #selector(M.menuRevealInFinder(_:))),
        ToolbarAction("diskMap", "Disk Map", "chart.pie", #selector(M.menuShowDiskMap(_:))),
        ToolbarAction("shelf", "Show Shelf", "tray.full", #selector(M.menuShowShelf(_:))),
        ToolbarAction("compare", "Compare Folders", "arrow.left.arrow.right.square",
                      #selector(M.menuCompareFolders(_:))),
        ToolbarAction("transfers", "Show Transfers", "arrow.left.arrow.right", #selector(M.menuShowTransfers(_:))),
        ToolbarAction("palette", "Command Palette", "command", #selector(M.menuCommandPalette(_:))),
        ToolbarAction("clean", "Clean This Folder", "sparkles", #selector(M.menuCleanFolder(_:))),
    ]

    /// Actions that only exist while a beta is on. Hidden rather than
    /// disabled: a button that cannot do anything is worse than no button.
    static var available: [ToolbarAction] {
        all.filter { $0.id != "clean" || Prefs.cleanFolder }
    }

    /// Puts a beta's button in the bar when the beta is switched on.
    ///
    /// Adding it to `defaultIDs` is not enough: anybody who has ever touched
    /// the toolbar has a stored list, and a new id never reaches it — so the
    /// button existed in the right-click menu and nowhere else, which is not
    /// what "add a sparkle in the toolbar" means. Only ever adds, and only
    /// once: removing it by hand afterwards sticks.
    static func placeBetaButtons() {
        guard Prefs.cleanFolder else { return }
        guard Settings.object(forKey: "cleanButtonPlaced") as? Bool != true else { return }
        Settings.set(true, forKey: "cleanButtonPlaced")
        var ids = enabledIDs
        guard !ids.contains("clean") else { return }
        ids.append("clean")
        let order = all.map(\.id)
        ids.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        enabledIDs = ids
    }

    static func action(id: String) -> ToolbarAction? { all.first { $0.id == id } }

    /// The view each segment of the view-mode pill stands for.
    static let viewModes: [String: ViewMode] = [
        "listView": .list, "iconView": .icon, "columnView": .column,
    ]

    /// The key bound to whatever command shares this selector, written the way
    /// a menu writes it.
    static func shortcutDisplay(for selector: Selector) -> String? {
        guard let command = CommandRegistry.all.first(where: { $0.selector == selector }) else {
            return nil
        }
        return CommandRegistry.shortcut(for: command)?.display
    }

    static let defaultIDs = ["up", "listView", "iconView", "columnView", "hidden",
                             "find", "copyPath", "favourite", "newFolder", "terminal"]

    /// The chosen buttons, in order. Unknown ids from an older build are dropped
    /// rather than crashing the bar.
    static var enabledIDs: [String] {
        get {
            guard let stored = Settings.stringArray(forKey: "toolbarActions") else {
                return defaultIDs
            }
            return stored.filter { action(id: $0) != nil }
        }
        set {
            Settings.set(newValue, forKey: "toolbarActions")
            NotificationCenter.default.post(name: .soquelToolbarChanged, object: nil)
        }
    }

    static func reset() {
        enabledIDs = defaultIDs
    }

    /// Keys owned outside Prefs that also move into settings.json.
    static let migratedKeys = ["toolbarActions", "visibleColumns", "shortcutOverrides", "sidebarLayout", "columnWidths"]
}

extension Notification.Name {
    static let soquelToolbarChanged = Notification.Name("app.soquel.toolbarChanged")
}

/// A toolbar button that remembers the command it stands for. The click goes
/// through the toolbar first so the pane can take focus, and only then is the
/// command sent up the responder chain — the handlers behind these selectors
/// act on the focused pane, so a straight dispatch from an unfocused pane's
/// toolbar drove the other pane.
private final class ForwardingButton: NSButton {
    var forwarded: Selector?
}

/// The strip of buttons under the filter field. Right-click it to choose what
/// it shows.
final class PaneToolbarView: NSView {
    /// Called before a button's command is dispatched, so the pane that owns
    /// this toolbar can take focus first.
    var onActivate: (() -> Void)?

    /// The view the pane behind this bar is showing right now. The catalogue's
    /// view-mode segments read the global setting, and with per-folder views
    /// on the folder on screen can be in another one; the pill followed the
    /// setting and disagreed with the rows under it. Nil while the pane has
    /// nothing on screen, in which case no segment is on.
    var viewModeOnScreen: (() -> ViewMode?)?

    private var stack: NSStackView!
    /// Holds the stack so a bar narrower than its buttons scrolls instead of
    /// overlapping or dropping them.
    private var scroll: NSScrollView!
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func build() {
        stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The bar scrolls sideways when it is too narrow for its buttons.
        //
        // Every button carries a required width, so a narrow window cannot
        // satisfy them all: laying them out anyway put them on top of each
        // other, and letting the stack shed them collapsed the whole bar and
        // never brought it back. Scrolling keeps every button reachable at
        // any width, which is what the path bar underneath already does.
        scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.contentView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])

        menu = NSMenu()
        menu?.delegate = self

        for name in [Notification.Name.soquelToolbarChanged, .soquelThemeChanged] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.rebuild() })
        }
        rebuild()
    }

    /// Rebuilt rather than mutated: the set of buttons is small and the state on
    /// each one has to be re-read anyway.
    func rebuild() {
        Log.debug(.ui, "Toolbar rebuild · viewMode=\(Prefs.viewMode.rawValue) "
            + "· ids=\(ToolbarCatalogue.enabledIDs.joined(separator: ","))")
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Consecutive actions from the same group become one pill; everything
        // else stays a plain button.
        var index = 0
        // Filtered here rather than in `enabledIDs`, so a button belonging to
        // a beta that is off is not drawn but is also not forgotten: turning
        // the beta back on brings it back where it was.
        let available = Set(ToolbarCatalogue.available.map(\.id))
        let ids = ToolbarCatalogue.enabledIDs.filter { available.contains($0) }
        while index < ids.count {
            guard let action = ToolbarCatalogue.action(id: ids[index]) else { index += 1; continue }

            if let group = action.group {
                var members: [ToolbarAction] = []
                while index < ids.count,
                      let next = ToolbarCatalogue.action(id: ids[index]), next.group == group {
                    members.append(readingTheScreen(next))
                    index += 1
                }
                let pill = ToolbarPillView(actions: members)
                pill.onActivate = { [weak self] in self?.onActivate?() }
                stack.addArrangedSubview(pill)
                continue
            }
            index += 1

            let button = ForwardingButton()
            button.image = NSImage(systemSymbolName: action.currentSymbol,
                                   accessibilityDescription: action.currentTitle)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = action.tooltip
            button.setAccessibilityLabel(action.currentTitle)
            button.target = self
            button.action = #selector(forwardAction(_:))
            button.forwarded = action.selector
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true

            // A toggle that is on gets the accent, so the bar reports state
            // rather than just offering actions.
            if action.isOn?() == true {
                button.contentTintColor = Theme.accent
                button.setAccessibilityValue("on")
            } else {
                button.contentTintColor = .secondaryLabelColor
                button.setAccessibilityValue("off")
            }
            stack.addArrangedSubview(button)
        }
        needsDisplay = true
    }

    /// A view-mode segment that lights for the view on screen rather than the
    /// global setting, when the pane has said which that is.
    private func readingTheScreen(_ action: ToolbarAction) -> ToolbarAction {
        guard let viewModeOnScreen, let mode = ToolbarCatalogue.viewModes[action.id] else {
            return action
        }
        return action.withState { viewModeOnScreen() == mode }
    }

    /// Focuses the pane, then sends the button's real command up the
    /// responder chain, where the window controller resolves it against the
    /// now-correct focused pane.
    @objc private func forwardAction(_ sender: Any?) {
        guard let selector = (sender as? ForwardingButton)?.forwarded else { return }
        onActivate?()
        NSApp.sendAction(selector, to: nil, from: sender)
    }

    @objc private func toggleAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var enabled = ToolbarCatalogue.enabledIDs
        if let index = enabled.firstIndex(of: id) {
            enabled.remove(at: index)
        } else {
            // Keep the catalogue's order so the bar does not shuffle.
            enabled.append(id)
            let order = ToolbarCatalogue.all.map(\.id)
            enabled.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        ToolbarCatalogue.enabledIDs = enabled
    }

    @objc private func resetToolbar() {
        ToolbarCatalogue.reset()
    }
}

/// A segmented pill for a set of mutually exclusive actions, such as the three
/// view modes. The selected segment is filled rather than merely tinted, which
/// is the same readability rule the file list follows.
final class ToolbarPillView: NSView {
    /// Called before a segment's command is dispatched, so the pane that owns
    /// the toolbar can take focus first.
    var onActivate: (() -> Void)?

    private let actions: [ToolbarAction]
    private var buttons: [NSButton] = []
    private let selection = NSView()

    static let segmentWidth: CGFloat = 30
    static let height: CGFloat = 22

    /// Which segment is on, if any. One place, so the fill, the tint and the
    /// accessibility value cannot disagree.
    static func selectedIndex(in actions: [ToolbarAction]) -> Int? {
        actions.firstIndex { $0.isOn?() == true }
    }

    /// For tests: where the fill is, and whether it is showing.
    var selectionState: (index: Int?, frame: NSRect, hidden: Bool) {
        (Self.selectedIndex(in: actions), selection.frame, selection.isHidden)
    }

    var segmentFrames: [NSRect] { buttons.map(\.frame) }

    init(actions: [ToolbarAction]) {
        self.actions = actions
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Theme.style == .bevelled ? 0 : Self.height / 2
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        widthAnchor.constraint(
            equalToConstant: Self.segmentWidth * CGFloat(actions.count)
        ).isActive = true

        selection.wantsLayer = true
        selection.layer?.cornerRadius = Theme.style == .bevelled ? 0 : Self.height / 2
        addSubview(selection)

        for action in actions {
            let button = ForwardingButton()
            button.image = NSImage(systemSymbolName: action.currentSymbol,
                                   accessibilityDescription: action.currentTitle)
            button.isBordered = false
            button.toolTip = action.tooltip
            button.setAccessibilityLabel(action.currentTitle)
            button.target = self
            button.action = #selector(forwardAction(_:))
            button.forwarded = action.selector
            addSubview(button)
            buttons.append(button)
        }
        applyColors()

        let names = actions.map(\.id).joined(separator: ", ")
        let chosen = Self.selectedIndex(in: actions).map { "\($0) (\(actions[$0].id))" } ?? "none"
        Log.debug(.ui, "Pill built: [\(names)] · viewMode=\(Prefs.viewMode.rawValue) · on=\(chosen)")
    }

    /// Frames are computed rather than constrained: the segments are a fixed
    /// width, and the selection has to sit exactly on one of them.
    override func layout() {
        super.layout()
        // Segments share the pill's actual width rather than each taking a
        // fixed 30pt: if the bar compresses the pill at all, fixed widths put
        // the later segments outside it and the fill lands under the wrong one.
        let width = bounds.width / CGFloat(max(buttons.count, 1))
        let onIndex = Self.selectedIndex(in: actions)

        for (offset, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(offset) * width, y: 0, width: width, height: bounds.height
            )
        }
        // Hidden rather than left over the last selection: a stale fill under
        // an unselected segment reads as the wrong one being on.
        selection.isHidden = onIndex == nil
        if let onIndex, buttons.indices.contains(onIndex) {
            selection.frame = buttons[onIndex].frame
        }
        Log.debug(.ui, "Pill laid out: width=\(bounds.width) segments=\(buttons.count) "
            + "on=\(onIndex.map(String.init) ?? "none") fill=\(selection.frame) hidden=\(selection.isHidden)")
    }

    /// Focuses the pane, then sends the segment's real command up the
    /// responder chain, where the window controller resolves it against the
    /// now-correct focused pane.
    @objc private func forwardAction(_ sender: Any?) {
        guard let selector = (sender as? ForwardingButton)?.forwarded else { return }
        onActivate?()
        NSApp.sendAction(selector, to: nil, from: sender)
    }

    private func applyColors() {
        // A dynamic NSColor resolves against whatever appearance is current
        // when cgColor is asked for, which during construction is the
        // application's rather than this view's. Without this the pill draws
        // its light-mode colours in a dark window.
        layer?.cornerRadius = Theme.style == .bevelled ? 0 : Self.height / 2
        selection.layer?.cornerRadius = layer?.cornerRadius ?? 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.6).cgColor
            layer?.borderColor = Theme.hairline.cgColor
            // Grey, not the selection blue. Which of three views you are in is
            // not worth the loudest colour on screen, and the accent has to
            // stay reserved for the row you actually have selected.
            selection.layer?.backgroundColor = Theme.selectionFillInactive.cgColor
        }

        let onIndex = Self.selectedIndex(in: actions)
        for (offset, button) in buttons.enumerated() {
            let on = offset == onIndex
            // labelColor rather than white: the fill is now a light grey in
            // light mode, and a white glyph on it cannot be read.
            button.contentTintColor = on ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(on ? "on" : "off")
        }
        needsLayout = true
    }

    /// Colours are resolved against the effective appearance, so they are
    /// re-read whenever it changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

extension PaneToolbarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Show in Toolbar", action: nil, keyEquivalent: "").isEnabled = false

        let enabled = Set(ToolbarCatalogue.enabledIDs)
        for action in ToolbarCatalogue.available {
            let item = NSMenuItem(title: action.title, action: #selector(toggleAction(_:)), keyEquivalent: "")
            item.representedObject = action.id
            item.state = enabled.contains(action.id) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Toolbar", action: #selector(resetToolbar), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }
}
