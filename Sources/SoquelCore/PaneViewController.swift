import AppKit

protocol PaneDelegate: AnyObject {
    func pane(_ pane: PaneViewController, openInOppositePane url: URL)
    func paneDidFocus(_ pane: PaneViewController)
    func pane(_ pane: PaneViewController, didReportStatus text: String)
    func pane(_ pane: PaneViewController, didChangeSelection urls: [URL])
    func paneDidChangeTabs(_ pane: PaneViewController)
}

/// A pane owns a stack of tabs, a breadcrumb path bar, and the visible file list.
final class PaneViewController: NSViewController, FileListDelegate, NSTextFieldDelegate {
    weak var delegate: PaneDelegate?

    private(set) var tabs: [FileListViewController] = []
    private(set) var activeIndex = 0

    var activeList: FileListViewController? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    /// Identity in the window's pane tree, which is what the tree stores
    /// rather than an index that shifts as panes come and go.
    let id = UUID()

    var currentURL: URL? { activeList?.url }

    private var tabBar: NSStackView!
    private var tabBarScroll: NSScrollView!
    /// Outside the scrolling stack. Pinned to the end of the tabs it scrolls
    /// away with them, and the point of it is to be there when there are
    /// already too many tabs to see.
    private var addTabButton: NSButton!
    private var pathBar: NSStackView!
    private var pathBarScroll: NSScrollView!
    private var pathField: NSTextField!
    private var toolbar: PaneToolbarView!
    private var filterField: NSSearchField!
    private var toolbarObserver: NSObjectProtocol?
    /// Column view replaces the list entirely, so it lives beside it here
    /// rather than inside the list controller's own layout.
    private var columnBrowser: ColumnBrowserView!
    private var contentView: NSView!
    private var focusIndicator: NSView!

    private var isFocused = false

    init(url: URL) {
        super.init(nibName: nil, bundle: nil)
        tabs = [makeList(url: url)]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Construction

    private func makeList(url: URL) -> FileListViewController {
        let list = FileListViewController(url: url)
        list.delegate = self
        return list
    }

    override func loadView() {
        let container = ThemedContainerView()
        container.wantsLayer = true
        container.onAppearanceChange = { [weak self] in self?.applyTheme() }

        focusIndicator = NSView()
        focusIndicator.wantsLayer = true
        focusIndicator.layer?.backgroundColor = Theme.accent.cgColor
        focusIndicator.translatesAutoresizingMaskIntoConstraints = false

        tabBar = NSStackView()
        tabBar.orientation = .horizontal
        tabBar.spacing = 3
        tabBar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabBarScroll = NSScrollView()
        tabBarScroll.documentView = tabBar
        tabBarScroll.hasHorizontalScroller = false
        tabBarScroll.hasVerticalScroller = false
        tabBarScroll.drawsBackground = false
        tabBarScroll.translatesAutoresizingMaskIntoConstraints = false

        addTabButton = NSButton()
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addTabButton.isBordered = false
        addTabButton.target = self
        addTabButton.action = #selector(tabAddClicked)
        addTabButton.toolTip = "New tab"
        addTabButton.setAccessibilityLabel("New tab")
        addTabButton.translatesAutoresizingMaskIntoConstraints = false

        // A deep path must scroll inside the pane, never widen the window.
        pathBar = NSStackView()
        pathBar.orientation = .horizontal
        pathBar.spacing = 0
        pathBar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        // The filter sits at the top, with the toolbar directly beneath it.
        filterField = NSSearchField()
        filterField.placeholderString = "Filter this folder"
        filterField.font = .systemFont(ofSize: 12)
        filterField.target = self
        filterField.action = #selector(paneFilterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityLabel("Filter this folder")
        filterField.translatesAutoresizingMaskIntoConstraints = false

        toolbar = PaneToolbarView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // Clicking the path bar switches it to a typable field. ⇧⌘G exists, but
        // the research is clear people expect to click and type, and judge the
        // modal go-to-folder a worse substitute rather than an equivalent.
        let pathClick = NSClickGestureRecognizer(target: self, action: #selector(beginEditingPathFromClick))
        pathClick.numberOfClicksRequired = 1

        pathBarScroll = NSScrollView()
        pathBarScroll.documentView = pathBar
        pathBarScroll.hasHorizontalScroller = false
        pathBarScroll.hasVerticalScroller = false
        pathBarScroll.drawsBackground = false
        pathBarScroll.translatesAutoresizingMaskIntoConstraints = false
        pathBarScroll.addGestureRecognizer(pathClick)

        pathField = NSTextField()
        pathField.delegate = self
        pathField.isHidden = true
        pathField.font = Theme.path
        pathField.target = self
        pathField.action = #selector(pathFieldCommitted)
        pathField.translatesAutoresizingMaskIntoConstraints = false

        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        columnBrowser = ColumnBrowserView()
        columnBrowser.translatesAutoresizingMaskIntoConstraints = false
        columnBrowser.isHidden = true
        columnBrowser.onOpen = { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { NSWorkspace.shared.open(url) }
        }
        // Column view keeps its own selection, so it has to report it the same
        // way the table does or the inspector and status bar go stale.
        columnBrowser.onSelect = { [weak self] url, _ in
            guard let self else { return }
            self.activeList?.setColumnSelection([url])
            self.delegate?.pane(self, didChangeSelection: [url])
            self.delegate?.pane(self, didReportStatus: url.lastPathComponent)
        }
        // Return renames, Space previews, Delete trashes — in columns too.
        columnBrowser.onKeyDown = { [weak self] event in
            self?.activeList?.handleKeyDown(event) ?? false
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(focusIndicator)
        container.addSubview(tabBarScroll)
        container.addSubview(addTabButton)
        container.addSubview(filterField)
        container.addSubview(toolbar)
        container.addSubview(pathBarScroll)
        container.addSubview(pathField)
        container.addSubview(divider)
        container.addSubview(contentView)
        container.addSubview(columnBrowser)

        NSLayoutConstraint.activate([
            focusIndicator.topAnchor.constraint(equalTo: container.topAnchor),
            focusIndicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            focusIndicator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            focusIndicator.heightAnchor.constraint(equalToConstant: Theme.focusBarHeight),

            tabBarScroll.topAnchor.constraint(equalTo: focusIndicator.bottomAnchor),
            tabBarScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBarScroll.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -2),
            tabBarScroll.heightAnchor.constraint(equalToConstant: 28),

            addTabButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            addTabButton.centerYAnchor.constraint(equalTo: tabBarScroll.centerYAnchor),
            addTabButton.widthAnchor.constraint(equalToConstant: 22),
            tabBar.heightAnchor.constraint(equalTo: tabBarScroll.heightAnchor),

            filterField.topAnchor.constraint(equalTo: tabBarScroll.bottomAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),

            toolbar.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 3),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 26),

            pathBarScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pathBarScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            pathBarScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pathBarScroll.heightAnchor.constraint(equalToConstant: 22),
            pathBar.heightAnchor.constraint(equalTo: pathBarScroll.heightAnchor),

            pathField.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pathField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            pathField.heightAnchor.constraint(equalToConstant: 22),

            divider.topAnchor.constraint(equalTo: pathBarScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            columnBrowser.topAnchor.constraint(equalTo: divider.bottomAnchor),
            columnBrowser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            columnBrowser.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            columnBrowser.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        showActiveTab()
        applyViewMode()
        rebuildTabBar()
        rebuildPathBar()
        setFocused(false)
    }

    /// A layer's backgroundColor is a resolved CGColor, so it does not follow a
    /// theme reload or a light/dark switch on its own.
    func applyTheme() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            focusIndicator.layer?.backgroundColor = Theme.accent.cgColor
        }
        rebuildPathBar()
        // Tabs read the colours and the corner radius when they are built, so
        // a theme change has to build them again or the old theme's grey and
        // square corners stay on screen.
        rebuildTabBar()
        for tab in tabs where tab.isViewLoaded {
            tab.applyBackground()
            tab.view.needsDisplay = true
        }
        view.needsDisplay = true
    }


    // MARK: - Tabs

    func addTab(url: URL, activate: Bool = true) {
        let list = makeList(url: url)
        tabs.append(list)
        if activate { activeIndex = tabs.count - 1 }
        showActiveTab()
        rebuildTabBar()
        rebuildPathBar()
        delegate?.paneDidChangeTabs(self)
    }

    /// Returns false when the last tab would be closed — the window decides
    /// whether that means closing the pane.
    @discardableResult
    func closeActiveTab() -> Bool {
        closeTab(at: activeIndex)
    }

    /// Closing a tab that is not the active one must not move the selection to
    /// a different folder. Whatever was in front stays in front unless it is
    /// the thing being closed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        let closing = tabs.remove(at: index)
        closing.view.removeFromSuperview()
        closing.removeFromParent()
        activeIndex = Self.activeIndexAfterClosing(index, wasActive: activeIndex, remaining: tabs.count)
        showActiveTab()
        rebuildTabBar()
        rebuildPathBar()
        delegate?.paneDidChangeTabs(self)
        return true
    }

    /// Where the selection lands once tab `closed` has gone.
    ///
    /// Closing a tab to the left of the active one shifts it down by one, or
    /// the pane jumps to a folder nobody asked for. Closing the active one
    /// falls to the tab that took its place, and to the last tab when the
    /// closed one was at the end.
    static func activeIndexAfterClosing(_ closed: Int, wasActive: Int, remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        // Both branches clamp. The shift-down case looks like it cannot exceed
        // the end, and for the indices a real pane produces it cannot, but a
        // function that returns an out-of-range index for any input is one
        // subscript away from a crash.
        if closed < wasActive { return min(wasActive - 1, remaining - 1) }
        return min(wasActive, remaining - 1)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        showActiveTab()
        rebuildTabBar()
        rebuildPathBar()
    }

    func nextTab() { selectTab(at: (activeIndex + 1) % max(tabs.count, 1)) }
    func previousTab() { selectTab(at: (activeIndex - 1 + tabs.count) % max(tabs.count, 1)) }

    private func showActiveTab() {
        guard let list = activeList else { return }
        for child in children where child !== list {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        if list.parent !== self {
            addChild(list)
            list.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(list.view)
            NSLayoutConstraint.activate([
                list.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                list.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                list.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                list.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        if isFocused { list.focusTable() }
    }

    private func rebuildTabBar() {
        for sub in tabBar.arrangedSubviews { tabBar.removeArrangedSubview(sub); sub.removeFromSuperview() }
        // A pane always has at least one tab, and that tab is the folder in
        // front of you — so there is always something to show and the bar never
        // hides. Hiding it below two tabs also hid the plus, which is exactly
        // the control someone with one tab is looking for.
        tabBarScroll.isHidden = false
        addTabButton.isHidden = false

        for (index, list) in tabs.enumerated() {
            let name = list.url.lastPathComponent.isEmpty ? "/" : list.url.lastPathComponent
            let tab = TabItemView(title: name, active: index == activeIndex, closable: tabs.count > 1)
            tab.toolTip = list.url.path
            tab.onSelect = { [weak self] in
                self?.selectTab(at: index)
                self?.activeList?.focusTable()
            }
            tab.onClose = { [weak self] in
                self?.closeTab(at: index)
                self?.activeList?.focusTable()
            }
            tabBar.addArrangedSubview(tab)
        }
    }

    /// Opens the folder the active tab is showing, which is what a new tab in
    /// a file manager means — not home, and not the last place you happened
    /// to be.
    @objc private func tabAddClicked() {
        guard let url = currentURL else { return }
        addTab(url: url)
        activeList?.focusTable()
    }

    // MARK: - Path bar

    /// Whether a slash goes after this crumb.
    ///
    /// The root's own label is "/", so following it with a separator wrote
    /// "//Applications". Nothing follows the last crumb either.
    static func breadcrumbNeedsSeparator(after name: String, isLast: Bool) -> Bool {
        !isLast && name != "/"
    }

    private func rebuildPathBar() {
        for sub in pathBar.arrangedSubviews { pathBar.removeArrangedSubview(sub); sub.removeFromSuperview() }
        guard let url = currentURL else { return }

        var components: [URL] = []
        var cursor: URL? = url
        while let current = cursor {
            components.append(current)
            cursor = parentDirectoryURL(of: current)
        }
        components.reverse()

        for (i, component) in components.enumerated() {
            let name = component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent
            let button = NSButton(title: name, target: self, action: #selector(breadcrumbClicked(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            let isCurrent = i == components.count - 1
            button.font = isCurrent ? Theme.pathCurrent : Theme.path
            button.contentTintColor = isCurrent ? Theme.accent : .secondaryLabelColor
            button.identifier = NSUserInterfaceItemIdentifier(component.path)
            pathBar.addArrangedSubview(button)
            if Self.breadcrumbNeedsSeparator(after: name, isLast: i == components.count - 1) {
                let sep = NSTextField(labelWithString: "/")
                sep.textColor = .tertiaryLabelColor
                sep.font = Theme.path
                pathBar.addArrangedSubview(sep)
            }
        }
    }

    @objc private func paneFilterChanged() {
        activeList?.setFilter(filterField.stringValue)
    }

    /// Keeps the toolbar's toggle states honest after a command changes one.
    func refreshToolbar() {
        // Deferred by one turn of the runloop. A toolbar button's action is
        // sent from inside the cell's mouse tracking, so rebuilding here frees
        // the very button that is mid-click and leaves AppKit drawing a view
        // that no longer exists.
        DispatchQueue.main.async { [weak self] in self?.toolbar?.rebuild() }
    }

    /// Shows either the list/icon view or the column browser.
    func applyViewMode() {
        guard isViewLoaded else { return }
        let columns = (activeList?.mode ?? Prefs.viewMode) == .column
        columnBrowser.isHidden = !columns
        contentView.isHidden = columns
        if columns, let url = currentURL, columnBrowser.deepestURL?.standardizedFileURL != url.standardizedFileURL {
            columnBrowser.show(url)
        }
    }

    /// Only an empty stretch of the bar starts editing; a click that landed on
    /// a breadcrumb button never reaches here.
    @objc private func beginEditingPathFromClick() {
        beginEditingPath()
    }

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        activeList?.navigate(to: URL(fileURLWithPath: path))
        activeList?.focusTable()
    }

    /// Whether the path field really took focus. `makeFirstResponder` is
    /// reached through an optional window, so nil means the pane is in no
    /// window at all, and false means the responder in place refused to
    /// resign — an inline rename holding a name AppKit will not accept does
    /// exactly that. Only true leaves a field that can be typed in.
    static func pathFieldTookFocus(_ firstResponderMoved: Bool?) -> Bool {
        firstResponderMoved == true
    }

    func beginEditingPath() {
        guard let url = currentURL else { return }
        pathField.stringValue = url.path
        // The field has to be on show before it can take first responder.
        pathField.isHidden = false
        pathBarScroll.isHidden = true
        // The result of the move used to be discarded and the breadcrumbs
        // hidden for good. When the move failed the pane was left with no path
        // bar and a field with no editor behind it: nothing was selected,
        // typing went nowhere, and Escape never reached
        // control(_:textView:doCommandBy:) to put the bar back, so the pane
        // stayed dead until the user navigated some other way.
        guard Self.pathFieldTookFocus(view.window?.makeFirstResponder(pathField)),
              let editor = pathField.currentEditor() else {
            endEditingPath()
            return
        }
        editor.selectAll(nil)
    }

    @objc private func pathFieldCommitted() {
        // Paths pasted from a terminal often arrive quoted or with a newline.
        var typed = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.count > 1, typed.hasPrefix("'"), typed.hasSuffix("'") { typed = String(typed.dropFirst().dropLast()) }
        if typed.count > 1, typed.hasPrefix("\""), typed.hasSuffix("\"") { typed = String(typed.dropFirst().dropLast()) }
        let expanded = (typed as NSString).expandingTildeInPath
        endEditingPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            NSSound.beep()
            return
        }
        let target = URL(fileURLWithPath: expanded)
        if isDir.boolValue {
            activeList?.navigate(to: target)
        } else {
            NSWorkspace.shared.open(target)
        }
        activeList?.focusTable()
    }

    func endEditingPath() {
        pathField.isHidden = true
        pathBarScroll.isHidden = false
    }

    /// Escape abandons Go to Folder and puts the breadcrumbs back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pathField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endEditingPath()
        activeList?.focusTable()
        return true
    }

    // MARK: - Focus

    func setFocused(_ focused: Bool) {
        isFocused = focused
        // Presence of the bar, not just its colour, carries the focus state.
        focusIndicator.isHidden = !focused
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            focusIndicator.layer?.backgroundColor = Theme.accent.cgColor
        }
        view.setAccessibilityLabel(
            (focused ? "Focused pane" : "Pane") + ": " + (currentURL?.lastPathComponent ?? "")
        )
    }

    func focus() {
        activeList?.focusTable()
    }

    // MARK: - FileListDelegate

    func fileList(_ list: FileListViewController, didNavigateTo url: URL) {
        guard list === activeList else { return }
        if (activeList?.mode ?? Prefs.viewMode) == .column { columnBrowser.show(url) }
        rebuildPathBar()
        rebuildTabBar()
        delegate?.paneDidChangeTabs(self)
    }

    func fileList(_ list: FileListViewController, openInNewTab url: URL) {
        addTab(url: url)
    }

    func fileList(_ list: FileListViewController, openInOppositePane url: URL) {
        delegate?.pane(self, openInOppositePane: url)
    }

    func fileListDidRequestFocus(_ list: FileListViewController) {
        delegate?.paneDidFocus(self)
    }

    func fileList(_ list: FileListViewController, didReportStatus text: String) {
        guard list === activeList else { return }
        delegate?.pane(self, didReportStatus: text)
    }

    func fileList(_ list: FileListViewController, didChangeSelection urls: [URL]) {
        guard list === activeList else { return }
        delegate?.pane(self, didChangeSelection: urls)
    }
}
