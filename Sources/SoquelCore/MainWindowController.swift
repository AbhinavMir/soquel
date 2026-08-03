import AppKit

/// Owns the sidebar, the pane split view, the status bar, and all menu command
/// routing for one window.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private var sidebar: SidebarViewController!
    /// Holds the pane arrangement. Its single subview is whatever the tree
    /// currently describes, so outerSplit's arranged subview never changes.
    private var paneContainer: NSView!
    /// How the panes are arranged. Vertical and horizontal splits can mix.
    private var tree: PaneNode?
    private var panesByID: [UUID: PaneViewController] = [:]
    /// Divider fractions per split, so rebuilding does not undo a manual drag.
    private var splitFractions: [UUID: [CGFloat]] = [:]

    /// The panes in reading order — left to right, then top to bottom.
    private var panes: [PaneViewController] {
        (tree?.leaves ?? []).compactMap { panesByID[$0] }
    }
    private var focusedIndex = 0
    private var outerSplit: NSSplitView!

    private var statusLeft: NSTextField!
    private var statusRight: NSTextField!
    private var inspector: InspectorView!
    /// Set once the split has been given a real width to divide.
    private var hasPositionedSplits = false
    private var activityToken: UUID?
    private var themeObserver: NSObjectProtocol?
    private let searchController = SearchWindowController()
    private let serverController = ConnectToServerController()
    private let archiveViewer = ArchiveViewerController()
    private let batchRenamer = BatchRenameController()

    static let maximumPanes = 4

    var focusedPane: PaneViewController? {
        panes.indices.contains(focusedIndex) ? panes[focusedIndex] : nil
    }

    private var focusedList: FileListViewController? { focusedPane?.activeList }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            // No .fullSizeContentView. The title bar is opaque, so extending the
            // content behind it does not buy a look — it just hides the top 28
            // points of the pane, which is exactly where the tab bar sits.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soquel"
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("SoquelMainWindow")
        window.minSize = NSSize(width: 640, height: 380)
        self.init(window: window)
        window.delegate = self
        build()
        restoreSession()
        window.center()
    }

    // MARK: - Construction

    private func build() {
        guard let window else { return }

        sidebar = SidebarViewController()
        sidebar.delegate = self

        // paneSplit is positioned by outerSplit's own frame-based layout, so it
        // must keep its autoresizing translation.
        paneContainer = NSView()

        outerSplit = NSSplitView()
        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        inspector = InspectorView()
        inspector.isHidden = !Prefs.showInspector

        outerSplit.addArrangedSubview(sidebar.view)
        outerSplit.addArrangedSubview(paneContainer)
        outerSplit.addArrangedSubview(inspector)

        statusLeft = NSTextField(labelWithString: "")
        statusLeft.font = Theme.status
        statusLeft.textColor = .secondaryLabelColor
        statusLeft.lineBreakMode = .byTruncatingTail

        statusRight = NSTextField(labelWithString: "")
        statusRight.font = Theme.status
        statusRight.textColor = Theme.accent
        statusRight.alignment = .right
        statusRight.lineBreakMode = .byTruncatingHead

        let statusBar = NSStackView(views: [statusLeft, statusRight])
        statusBar.orientation = .horizontal
        statusBar.distribution = .fill
        statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        statusLeft.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRight.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        statusDivider.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(outerSplit)
        root.addSubview(statusDivider)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            outerSplit.topAnchor.constraint(equalTo: root.topAnchor),
            outerSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outerSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusDivider.topAnchor.constraint(equalTo: outerSplit.bottomAnchor),
            statusDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: statusDivider.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        window.contentView = root

        // NSSplitView hands the first subview everything unless told otherwise;
        // without this the sidebar filled the window and the panes got no width.
        // Positions are applied once the window has its real width — setting
        // them here, against a zero-width split, left both dividers wrong.
        root.layoutSubtreeIfNeeded()
        applyDefaultSplitPositions()

        activityToken = OperationEngine.shared.addActivityObserver { [weak self] count, label in
            guard let self else { return }
            self.statusRight.stringValue = count > 0 ? (label ?? "Working…") : ""
        }

        // Clicking the activity text opens the queue, which is where the
        // throughput and the pause button live.
        statusRight.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(menuShowTransfers(_:)))
        )

        themeObserver = NotificationCenter.default.addObserver(
            forName: .soquelThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
    }

    private func applyTheme() {
        statusRight.textColor = Theme.accent
        for pane in panes { pane.applyTheme() }
        window?.contentView?.needsDisplay = true
    }

    /// Below this a pane cannot show a filename and a size, so splitting past it
    /// is refused rather than producing slivers.
    static let minimumPaneWidth: CGFloat = 280
    static let minimumPaneHeight: CGFloat = 160
    static let defaultSidebarWidth: CGFloat = 190
    static let minimumSidebarWidth: CGFloat = 140
    static let maximumSidebarWidth: CGFloat = 340
    static let defaultInspectorWidth: CGFloat = 280
    static let minimumInspectorWidth: CGFloat = 220

    /// Creates a pane and puts it in the tree, splitting `target` when one is
    /// given and starting the tree when there is none.
    @discardableResult
    private func addPane(url: URL, splitting target: UUID? = nil, vertical: Bool = true) -> PaneViewController? {
        guard panes.count < Self.maximumPanes else { NSSound.beep(); return nil }
        let pane = PaneViewController(url: url)
        pane.delegate = self
        panesByID[pane.id] = pane

        if let tree, let target {
            self.tree = tree.splitting(target, vertical: vertical, into: pane.id, splitID: UUID())
        } else if let tree {
            self.tree = tree.splitting(tree.leaves.last ?? pane.id, vertical: vertical,
                                       into: pane.id, splitID: UUID())
        } else {
            tree = .leaf(pane.id)
        }

        rebuildPaneViews()
        focusPane(id: pane.id)
        return pane
    }

    /// Rebuilds the split-view hierarchy from the tree.
    ///
    /// Rebuilding wholesale rather than surgically: the pane controllers are
    /// held in `panesByID`, so re-parenting their views costs nothing, and the
    /// alternative is a second representation of the same shape that can drift
    /// from the first. Divider positions are captured first and put back after,
    /// so a manual drag survives a split somewhere else in the window.
    private func rebuildPaneViews() {
        Log.debug(.panes, "Pane tree: \(panes.count) pane(s), depth \(tree?.depth ?? 0)")
        captureSplitFractions()
        for subview in paneContainer.subviews { subview.removeFromSuperview() }
        guard let tree else { return }

        let built = makeView(for: tree)
        built.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            built.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
            built.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
        ])

        // Positions can only be set once the split views have a size.
        DispatchQueue.main.async { [weak self] in self?.applySplitFractions() }
    }

    private func makeView(for node: PaneNode) -> NSView {
        switch node {
        case .leaf(let id):
            guard let pane = panesByID[id] else { return NSView() }
            pane.view.translatesAutoresizingMaskIntoConstraints = true
            return pane.view

        case .split(let id, let vertical, let children):
            let split = NSSplitView()
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.delegate = self
            split.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
            for child in children {
                split.addArrangedSubview(makeView(for: child))
            }
            return split
        }
    }

    /// Records where each divider sits, as a fraction of the split's length.
    private func captureSplitFractions() {
        for split in liveSplitViews() {
            guard let key = split.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { continue }
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            guard total > 1 else { continue }
            let sizes = split.arrangedSubviews.map {
                (split.isVertical ? $0.frame.width : $0.frame.height) / total
            }
            guard sizes.allSatisfy({ $0 > 0 }) else { continue }
            splitFractions[key] = sizes
        }
    }

    /// Puts the dividers back where they were, and shares out evenly any split
    /// whose shape has changed since it was measured.
    private func applySplitFractions() {
        for split in liveSplitViews() {
            let key = split.identifier.flatMap { UUID(uuidString: $0.rawValue) }
            let count = split.arrangedSubviews.count
            guard count > 1 else { continue }
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            guard total > 1 else { continue }

            let remembered = key.flatMap { splitFractions[$0] }
            let fractions = (remembered?.count == count)
                ? remembered!
                : Array(repeating: 1 / CGFloat(count), count: count)

            var offset: CGFloat = 0
            for index in 0..<(count - 1) {
                offset += fractions[index] * total
                split.setPosition(offset, ofDividerAt: index)
                offset += split.dividerThickness
            }
        }
    }

    private func liveSplitViews() -> [NSSplitView] {
        var found: [NSSplitView] = []
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView, split !== outerSplit { found.append(split) }
            for subview in view.subviews { walk(subview) }
        }
        if let root = paneContainer?.subviews.first { walk(root) }
        return found
    }

    /// Shares every split out evenly, discarding remembered positions.
    private func equalizePanes() {
        splitFractions.removeAll()
        applySplitFractions()
    }

    /// True when the focused pane still has room to be halved.
    private func canSplit(vertical: Bool) -> Bool {
        guard panes.count < Self.maximumPanes else { return false }
        guard let view = focusedPane?.view else { return true }
        let available = vertical ? view.bounds.width : view.bounds.height
        guard available > 1 else { return true }  // geometry not ready yet
        let minimum = vertical ? Self.minimumPaneWidth : Self.minimumPaneHeight
        return available / 2 >= minimum
    }

    func focusPane(id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        focusPane(at: index)
    }

    func focusPane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        focusedIndex = index
        for (i, pane) in panes.enumerated() { pane.setFocused(i == index) }
        panes[index].focus()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        guard let url = focusedPane?.currentURL else { return }
        window?.title = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent

        // Assigning representedURL makes AppKit fetch the folder's document icon
        // and display name. Doing that inline hung the app at launch: the call
        // arrives from inside becomeFirstResponder while the window is still
        // being built, and the icon lookup blocks. The proxy icon is worth
        // keeping, so it is set once the window is up rather than dropped.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            guard self.focusedPane?.currentURL == url else { return }
            window.representedURL = url
        }
    }

    // MARK: - Session

    private func restoreSession() {
        let saved = Prefs.sessionPanes
        let activeTabs = Prefs.sessionActiveTabs
        let fm = FileManager.default
        var restored = false

        for (paneIndex, paneTabs) in saved.prefix(Self.maximumPanes).enumerated() {
            let valid = paneTabs.filter { fm.fileExists(atPath: $0) }
            guard let first = valid.first else { continue }
            addPane(url: URL(fileURLWithPath: first))
            for extra in valid.dropFirst() {
                panes.last?.addTab(url: URL(fileURLWithPath: extra), activate: false)
            }
            // Tabs whose folders vanished shift the indices, so clamp rather
            // than trusting the saved number.
            if activeTabs.indices.contains(paneIndex) {
                panes.last?.selectTab(at: min(activeTabs[paneIndex], valid.count - 1))
            }
            restored = true
        }

        if !restored {
            addPane(url: fm.homeDirectoryForCurrentUser)
        }
        focusPane(at: 0)
    }

    func saveSession() {
        Prefs.sessionPanes = panes.map { pane in pane.tabs.map { $0.url.path } }
        Prefs.sessionActiveTabs = panes.map { $0.activeIndex }
    }

    func windowWillClose(_ notification: Notification) {
        debugLog("windowWillClose")
        saveSession()
    }

    deinit {
        debugLog("MainWindowController deinit")
        if let activityToken { OperationEngine.shared.removeActivityObserver(activityToken) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: - Pane commands

    /// Compares the focused pane against the other one, or against a folder
    /// the user picks when there is no other pane.
    /// Mounts a file server. Once mounted it is an ordinary path, so the
    /// focused pane simply navigates to it.
    @objc func menuConnectToServer(_ sender: Any?) {
        serverController.onMounted = { [weak self] mountPoint in
            self?.focusedList?.navigate(to: mountPoint)
            self?.statusLeft.stringValue = "Mounted \(mountPoint.lastPathComponent)"
            self?.sidebar.rebuild()
        }
        serverController.present(for: self)
    }

    @objc func menuCompareFolders(_ sender: Any?) {
        guard let left = focusedList?.url else { return }
        if let other = panes.first(where: { $0 !== focusedPane })?.currentURL {
            FolderComparePanelController.shared.show(left: left, right: other)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder to compare “\(left.lastPathComponent)” against."
        panel.prompt = "Compare"
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let right = panel.url else { return }
            FolderComparePanelController.shared.show(left: left, right: right)
        }
    }

    @objc func menuSplitVertically(_ sender: Any?) { split(vertical: true) }
    @objc func menuSplitHorizontally(_ sender: Any?) { split(vertical: false) }

    /// Splits the focused pane, leaving every other pane alone.
    private func split(vertical: Bool) {
        Log.info(.panes, "Split \(vertical ? "vertically" : "horizontally") · \(panes.count) pane(s)")
        guard panes.count < Self.maximumPanes else { NSSound.beep(); return }
        guard canSplit(vertical: vertical) else {
            statusLeft.stringValue = vertical
                ? "This pane is too narrow to split"
                : "This pane is too short to split"
            NSSound.beep()
            return
        }
        let url = focusedPane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        addPane(url: url, splitting: focusedPane?.id, vertical: vertical)
    }

    /// Flips the split holding the focused pane, so a side-by-side pair becomes
    /// stacked without closing and reopening anything.
    @objc func menuRotatePaneSplit(_ sender: Any?) {
        guard let tree, let focused = focusedPane else { NSSound.beep(); return }
        self.tree = tree.rotatingContainer(of: focused.id)
        rebuildPaneViews()
        focusPane(id: focused.id)
    }

    @objc func menuClosePane(_ sender: Any?) {
        guard panes.count > 1, let tree, let closing = focusedPane else { NSSound.beep(); return }
        let survivor = tree.leaf(before: closing.id)
        self.tree = tree.removing(closing.id)
        panesByID.removeValue(forKey: closing.id)
        closing.view.removeFromSuperview()
        rebuildPaneViews()
        if let survivor, survivor != closing.id {
            focusPane(id: survivor)
        } else {
            focusPane(at: 0)
        }
    }

    @objc func menuFocusNextPane(_ sender: Any?) {
        guard !panes.isEmpty else { return }
        focusPane(at: (focusedIndex + 1) % panes.count)
    }

    @objc func menuFocusPreviousPane(_ sender: Any?) {
        guard !panes.isEmpty else { return }
        focusPane(at: (focusedIndex - 1 + panes.count) % panes.count)
    }

    @objc func menuFocusPaneByIndex(_ sender: NSMenuItem) {
        focusPane(at: sender.tag)
    }

    /// Swaps what two panes are showing rather than moving the panes: with a
    /// tree, moving a pane means restructuring, and the folders are what the
    /// user wanted swapped anyway.
    @objc func menuSwapPanes(_ sender: Any?) {
        guard panes.count > 1, let first = focusedPane else { return }
        let other = panes[(focusedIndex + 1) % panes.count]
        guard let here = first.currentURL, let there = other.currentURL else { return }
        first.activeList?.navigate(to: there)
        other.activeList?.navigate(to: here)
        focusPane(at: (focusedIndex + 1) % panes.count)
    }

    @objc func menuMoveToOppositePane(_ sender: Any?) {
        guard panes.count > 1, let list = focusedList else { NSSound.beep(); return }
        let urls = list.selectedURLs()
        guard !urls.isEmpty else { return }
        let target = panes[(focusedIndex + 1) % panes.count]
        target.activeList?.receive(urls, move: true)
    }

    @objc func menuCopyToOppositePane(_ sender: Any?) {
        guard panes.count > 1, let list = focusedList else { NSSound.beep(); return }
        let urls = list.selectedURLs()
        guard !urls.isEmpty else { return }
        let target = panes[(focusedIndex + 1) % panes.count]
        target.activeList?.receive(urls, move: false)
    }

    // MARK: - Tab commands

    @objc func menuNewTab(_ sender: Any?) {
        guard let url = focusedPane?.currentURL else { return }
        focusedPane?.addTab(url: url)
        focusedPane?.focus()
    }

    @objc func menuCloseTab(_ sender: Any?) {
        guard let pane = focusedPane else { return }
        if !pane.closeActiveTab() {
            if panes.count > 1 { menuClosePane(nil) } else { window?.performClose(nil) }
        }
    }

    @objc func menuNextTab(_ sender: Any?) { focusedPane?.nextTab(); focusedPane?.focus() }
    @objc func menuPreviousTab(_ sender: Any?) { focusedPane?.previousTab(); focusedPane?.focus() }

    // MARK: - Navigation commands

    @objc func menuGoBack(_ sender: Any?) { focusedList?.goBack() }
    @objc func menuGoForward(_ sender: Any?) { focusedList?.goForward() }
    @objc func menuGoUp(_ sender: Any?) { focusedList?.goUp() }
    @objc func menuOpen(_ sender: Any?) { focusedList?.openSelection() }

    @objc func menuGoHome(_ sender: Any?) {
        focusedList?.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func menuGoRoot(_ sender: Any?) {
        focusedList?.navigate(to: URL(fileURLWithPath: "/"))
    }

    @objc func menuGoToFolder(_ sender: Any?) {
        focusedPane?.beginEditingPath()
    }

    @objc func menuGoToGitRoot(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        guard let root = gitRoot(for: url) else {
            statusLeft.stringValue = "Not inside a Git repository"
            NSSound.beep()
            return
        }
        focusedList?.navigate(to: root)
    }

    // MARK: - File commands

    /// Pops the Open With list where the click happened, so changing which
    /// application opens something is one button rather than a right-click into
    /// a submenu. The list is the context menu's, built once.
    @objc func menuOpenWith(_ sender: Any?) {
        guard let list = focusedList, let menu = list.openWithMenu() else {
            statusLeft.stringValue = "Select a file first"
            return
        }
        let view = (sender as? NSView) ?? list.view
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: view.bounds.height + 2),
                   in: view)
    }

    @objc func menuToggleVerifyCopies(_ sender: Any?) {
        VerifiedCopy.isEnabled.toggle()
        statusLeft.stringValue = VerifiedCopy.isEnabled
            ? "Copies will be checksummed at both ends — slower, and it reads every byte twice"
            : "Copies will not be checksummed"
    }

    @objc func menuFindDuplicates(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        DuplicatesPanelController.shared.onChanged = { [weak self] in self?.focusedList?.reload() }
        DuplicatesPanelController.shared.show(roots: [url], over: window)
    }

    @objc func menuToggleSyncBrowsing(_ sender: Any?) {
        Prefs.syncBrowsing.toggle()
        statusLeft.stringValue = Prefs.syncBrowsing
            ? "Sync browsing on — selecting a folder shows it in the next pane"
            : "Sync browsing off"
        if Prefs.syncBrowsing, let pane = focusedPane, let list = focusedList {
            syncBrowse(from: pane, selection: list.selectedURLs())
        }
    }

    @objc func menuTogglePerFolderViews(_ sender: Any?) {
        FolderViewSettings.isEnabled.toggle()
        if FolderViewSettings.isEnabled, let list = focusedList {
            FolderViewSettings.record(list.url, viewMode: Prefs.viewMode, sortOrder: Prefs.sortOrder)
        } else {
            FolderViewSettings.forgetAll()
        }
        statusLeft.stringValue = FolderViewSettings.isEnabled
            ? "Each folder remembers its own view and sort"
            : "One view and sort for every folder; what was remembered is forgotten"
        propagateViewSettings()
    }

    @objc func menuRunCommand(_ sender: Any?) {
        CommandPanelController.shared.show(in: focusedList?.url, over: window)
    }

    @objc func menuMakeSymlink(_ sender: Any?) { focusedList?.makeSymlink() }
    @objc func menuNewFolder(_ sender: Any?) { focusedList?.newFolder() }
    @objc func menuNewFile(_ sender: Any?) { focusedList?.newFile() }
    @objc func menuRename(_ sender: Any?) { focusedList?.beginRename() }
    @objc func menuDuplicate(_ sender: Any?) { focusedList?.duplicateSelection() }
    @objc func menuTrash(_ sender: Any?) { focusedList?.trashSelection() }
    @objc func menuDeletePermanently(_ sender: Any?) { focusedList?.deleteSelectionPermanently() }
    @objc func menuCopyFiles(_ sender: Any?) { focusedList?.copySelection(cut: false) }
    @objc func menuCutFiles(_ sender: Any?) { focusedList?.copySelection(cut: true) }
    @objc func menuPasteFiles(_ sender: Any?) { focusedList?.pasteFiles() }
    @objc func menuSelectAll(_ sender: Any?) { focusedList?.selectAllItems() }
    @objc func menuInvertSelection(_ sender: Any?) { focusedList?.invertSelection() }
    @objc func menuQuickLook(_ sender: Any?) { focusedList?.toggleQuickLook() }
    @objc func menuRevealInFinder(_ sender: Any?) { focusedList?.revealInFinder() }
    @objc func menuFilter(_ sender: Any?) { focusedList?.beginFilter() }
    @objc func menuRefresh(_ sender: Any?) { focusedList?.reload() }

    /// The Edit menu's Undo uses the standard `undo:` selector so a focused text
    /// field undoes typing; this only runs when no editor claims it.
    @objc func undo(_ sender: Any?) { menuUndo(sender) }

    @objc func menuUndo(_ sender: Any?) {
        guard UndoStack.shared.canUndo else { NSSound.beep(); return }
        UndoStack.shared.undo { [weak self] label, error in
            guard let self else { return }
            if let error {
                self.focusedList?.showError(error)
            } else if let label {
                self.statusLeft.stringValue = "Undid \(label)"
            }
            for pane in self.panes { pane.activeList?.reload() }
        }
    }

    @objc func menuToggleHidden(_ sender: Any?) {
        Prefs.showHiddenFiles.toggle()
        for pane in panes {
            pane.refreshToolbar()
            for tab in pane.tabs { tab.reload() }
        }
    }

    @objc func menuToggleFoldersFirst(_ sender: Any?) {
        Prefs.foldersFirst.toggle()
        for pane in panes {
            pane.refreshToolbar()
            for tab in pane.tabs { tab.reload() }
        }
    }

    @objc func menuToggleSidebar(_ sender: Any?) {
        let hidden = sidebar.view.isHidden
        sidebar.view.isHidden = !hidden
        outerSplit.adjustSubviews()
        // adjustSubviews alone left the divider where it was, so hiding the
        // sidebar blanked its column instead of giving the width to the panes.
        applyDefaultSplitPositions()
    }

    /// What the favourite button acts on: the selected folder, or failing that
    /// the one being looked at. Selecting a folder and pressing the button
    /// should pin that folder rather than its parent.
    var favouriteTarget: URL? {
        if let selected = focusedList?.selectedURLs().first, selected.hasDirectoryPath {
            return selected
        }
        return focusedList?.url
    }

    /// Pins the folder, or unpins it when it is already pinned.
    ///
    /// One button doing both ways round: a star that fills when the folder is
    /// pinned is only honest if pressing it again takes the pin away.
    @objc func menuAddFavourite(_ sender: Any?) {
        guard let url = favouriteTarget else { return }
        var layout = SidebarStore.layout
        if let existing = layout.pin(for: url) {
            layout.removeItem(id: existing.id)
            SidebarStore.layout = layout
            statusLeft.stringValue = "Removed “\(url.lastPathComponent)” from the sidebar"
        } else {
            sidebar.pin(url)
            statusLeft.stringValue = "Pinned “\(url.lastPathComponent)” to the sidebar"
        }
    }

    /// Whether the toolbar's star should read as filled. Asks the key window,
    /// since the toolbar item is shared and the catalogue has no controller.
    static func favouriteIsOn() -> Bool {
        guard let controller = NSApp.keyWindow?.windowController as? MainWindowController,
              let url = controller.favouriteTarget else { return false }
        return SidebarStore.layout.isPinned(url)
    }

    @objc func menuSortByName(_ sender: Any?) { sort(by: .name) }
    @objc func menuSortBySize(_ sender: Any?) { sort(by: .size) }
    @objc func menuSortByKind(_ sender: Any?) { sort(by: .kind) }
    @objc func menuSortByDate(_ sender: Any?) { sort(by: .modified) }
    @objc func menuSortByExtension(_ sender: Any?) { sort(by: .ext) }
    @objc func menuSortByCreated(_ sender: Any?) { sort(by: .created) }

    /// Holding Shift adds the key as a tiebreaker instead of replacing the sort.
    private func sort(by key: SortKey) {
        let additive = NSEvent.modifierFlags.contains(.shift)
        focusedList?.setSort(key: key, additive: additive)
        propagateViewSettings()
    }

    @objc func menuReverseSort(_ sender: Any?) {
        focusedList?.reverseSort()
        propagateViewSettings()
    }

    @objc func menuClearSecondarySorts(_ sender: Any?) {
        focusedList?.clearSecondarySorts()
        propagateViewSettings()
    }

    // MARK: - View mode

    @objc func menuUseListView(_ sender: Any?) {
        Log.info(.ui, "View mode → list (was \(Prefs.viewMode.rawValue))")
        Prefs.viewMode = .list
        if let list = focusedList {
            FolderViewSettings.record(list.url, viewMode: .list, sortOrder: nil)
        }
        propagateViewSettings()
    }

    @objc func menuUseIconView(_ sender: Any?) {
        Log.info(.ui, "View mode → icon (was \(Prefs.viewMode.rawValue))")
        Prefs.viewMode = .icon
        if let list = focusedList {
            FolderViewSettings.record(list.url, viewMode: .icon, sortOrder: nil)
        }
        propagateViewSettings()
    }

    @objc func menuUseColumnView(_ sender: Any?) {
        Log.info(.ui, "View mode → column (was \(Prefs.viewMode.rawValue))")
        Prefs.viewMode = .column
        if let list = focusedList {
            FolderViewSettings.record(list.url, viewMode: .column, sortOrder: nil)
        }
        propagateViewSettings()
    }

    @objc func menuToggleFolderSizes(_ sender: Any?) {
        Prefs.calculateFolderSizes.toggle()
        FolderSizeCalculator.shared.clear()
        for pane in panes {
            pane.refreshToolbar()
            for tab in pane.tabs { tab.reload() }
        }
        statusLeft.stringValue = Prefs.calculateFolderSizes
            ? "Calculating folder sizes in the background"
            : "Folder sizes off"
    }

    // MARK: - Workspaces

    /// Captures the current arrangement under a name.
    @objc func menuSaveWorkspace(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Reopen this arrangement of panes and tabs by name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = focusedPane?.currentURL?.lastPathComponent ?? "Workspace"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let workspace = Workspace(
            name: name,
            panes: panes.map { pane in pane.tabs.map { $0.url.path } },
            activeTabs: panes.map(\.activeIndex),
            isVerticalSplit: rootSplitIsVertical,
            layout: tree?.indexed(by: panes.map(\.id))
        )
        WorkspaceStore.add(workspace)
        statusLeft.stringValue = "Saved workspace “\(name)”"
    }

    @objc func menuOpenWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let workspace = WorkspaceStore.all.first(where: { $0.id == id })
        else { return }
        apply(workspace)
    }

    @objc func menuManageWorkspaces(_ sender: Any?) {
        guard !WorkspaceStore.all.isEmpty else {
            statusLeft.stringValue = "No workspaces saved yet"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Workspaces"
        alert.informativeText = WorkspaceStore.all
            .map { "\($0.name) — \($0.summary)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Reveal workspaces.json")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([WorkspaceStore.fileURL])
        }
    }

    /// The orientation of the outermost split, which is what a workspace
    /// records. Nested arrangements are rebuilt as a single row or column.
    private var rootSplitIsVertical: Bool {
        if case .split(_, let vertical, _) = tree { return vertical }
        return true
    }

    /// Empties the window of panes.
    private func resetPanes() {
        for pane in panes { pane.view.removeFromSuperview() }
        panesByID.removeAll()
        splitFractions.removeAll()
        tree = nil
    }

    /// Rebuilds the window to match a saved arrangement.
    func apply(_ workspace: Workspace) {
        let surviving = workspace.survivingPanes()
        guard !surviving.isEmpty else {
            statusLeft.stringValue = "“\(workspace.name)” points at folders that no longer exist"
            NSSound.beep()
            return
        }

        resetPanes()

        // Panes are created first, then arranged: the saved layout refers to
        // them by position, and a pane whose folder has gone leaves a gap the
        // arrangement has to close.
        var created: [Int: UUID] = [:]
        for (position, tabs) in surviving.prefix(Self.maximumPanes).enumerated() {
            guard let first = tabs.first else { continue }
            guard let pane = addPane(url: URL(fileURLWithPath: first),
                                     splitting: tree?.leaves.last,
                                     vertical: workspace.isVerticalSplit) else { continue }
            created[position] = pane.id

            for extra in tabs.dropFirst() {
                pane.addTab(url: URL(fileURLWithPath: extra), activate: false)
            }
            let savedIndex = workspace.survivingPanesWithIndices()[position].index
            if workspace.activeTabs.indices.contains(savedIndex) {
                pane.selectTab(at: min(workspace.activeTabs[savedIndex], tabs.count - 1))
            }
        }

        // A workspace saved before nested splits has no layout, and reopens as
        // the single row or column it was saved as.
        if let saved = workspace.survivingLayout(),
           let rebuilt = PaneNode.rebuilt(from: saved, paneIDs: created) {
            tree = rebuilt
            rebuildPaneViews()
        }
        equalizePanes()
        focusPane(at: 0)

        let dropped = workspace.panes.count - surviving.count
        statusLeft.stringValue = dropped > 0
            ? "Opened “\(workspace.name)” — \(dropped) pane\(dropped == 1 ? "" : "s") skipped, folders missing"
            : "Opened “\(workspace.name)”"
    }

    /// Built fresh so newly saved workspaces appear without a relaunch.
    static func workspaceMenu() -> NSMenu {
        let menu = NSMenu()
        if WorkspaceStore.all.isEmpty {
            menu.addItem(withTitle: "No workspaces saved", action: nil, keyEquivalent: "")
            return menu
        }
        for workspace in WorkspaceStore.all {
            let item = NSMenuItem(title: workspace.name,
                                  action: #selector(menuOpenWorkspace(_:)), keyEquivalent: "")
            item.representedObject = workspace.id.uuidString
            item.toolTip = workspace.summary
            item.isEnabled = workspace.isUsable
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Archives

    @objc func menuBatchRename(_ sender: Any?) {
        guard let list = focusedList else { return }
        let urls = list.selectedURLs()
        guard urls.count > 1 else {
            // One file is an inline rename; the sheet is for a batch.
            list.beginRename()
            return
        }
        batchRenamer.present(for: self, urls: urls)
    }

    /// Reloads every open tab, after an operation that changed many names.
    func refreshAllPanes() {
        for pane in panes {
            for tab in pane.tabs where tab.isViewLoaded { tab.reload() }
        }
    }

    @objc func menuOpenArchive(_ sender: Any?) {
        guard let url = focusedList?.selectedURLs().first ?? focusedList?.url else { return }
        guard Archive.isArchive(url) else {
            statusLeft.stringValue = "Not an archive"
            NSSound.beep()
            return
        }
        archiveViewer.present(for: self, url: url)
    }

    @objc func menuToggleInspector(_ sender: Any?) {
        Prefs.showInspector.toggle()
        inspector.isHidden = !Prefs.showInspector
        outerSplit.adjustSubviews()
        applyDefaultSplitPositions()
        if Prefs.showInspector {
            inspector.show(focusedList?.selectedURLs() ?? [])
        }
        for pane in panes { pane.refreshToolbar() }
    }

    /// Where the two outer dividers belong in a split `total` points wide.
    ///
    /// A column that is off gets none of the width: its divider sits on its own
    /// edge — 0 for the sidebar, the trailing edge for the inspector — so the
    /// panes take the space rather than it being left blank.
    static func outerDividerPositions(
        total: CGFloat, sidebarShown: Bool, inspectorShown: Bool
    ) -> (sidebar: CGFloat, inspector: CGFloat) {
        (sidebarShown ? defaultSidebarWidth : 0,
         inspectorShown ? total - defaultInspectorWidth : total)
    }

    /// Puts the sidebar and the inspector at their default widths, gives a
    /// hidden one no width at all, and leaves the rest to the panes.
    ///
    /// The inspector divider is placed first: moving the right divider outward
    /// is what creates room for the panes, and doing it second would squeeze
    /// the sidebar instead.
    private func applyDefaultSplitPositions() {
        outerSplit.layoutSubtreeIfNeeded()
        let total = outerSplit.bounds.width
        guard total > Self.minimumSidebarWidth + Self.minimumPaneWidth else { return }

        let positions = Self.outerDividerPositions(
            total: total,
            sidebarShown: !sidebar.view.isHidden,
            inspectorShown: !inspector.isHidden
        )
        // Divider 1 used to be skipped whenever the inspector was off, and no
        // other code path moved it, so the inspector's 280pt stayed reserved
        // and blank for as long as the window was open.
        if outerSplit.arrangedSubviews.count >= 3 {
            outerSplit.setPosition(positions.inspector, ofDividerAt: 1)
        }
        outerSplit.setPosition(positions.sidebar, ofDividerAt: 0)
        hasPositionedSplits = true
        debugLog("split widths: " + outerSplit.arrangedSubviews.map { "\($0.frame.width)" }.joined(separator: ", "))
    }

    // MARK: - Shelf

    @objc func menuAddToShelf(_ sender: Any?) {
        guard let list = focusedList else { return }
        let urls = list.selectedURLs()
        guard !urls.isEmpty else {
            statusLeft.stringValue = "Nothing selected to put on the shelf"
            NSSound.beep()
            return
        }
        let added = Shelf.add(urls)
        statusLeft.stringValue = added == urls.count
            ? "\(Shelf.summary)"
            : "\(added) added, \(urls.count - added) already there — \(Shelf.summary)"
    }

    /// Scans the focused pane's folder and shows where the space went.
    @objc func menuShowDiskMap(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        let panel = DiskMapPanelController.shared
        panel.onReveal = { [weak self] target in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            let folder = isDirectory.boolValue ? target : target.deletingLastPathComponent()
            self?.focusedList?.navigate(to: folder)
            if !isDirectory.boolValue { self?.focusedList?.reload(selecting: target) }
            self?.window?.makeKeyAndOrderFront(nil)
        }
        panel.show(url)
    }

    @objc func menuShowShelf(_ sender: Any?) {
        let panel = ShelfPanelController.shared
        panel.destination = focusedList?.url
        panel.onDelivered = { [weak self] in self?.refreshAllPanes() }
        panel.show()
    }

    @objc func menuClearShelf(_ sender: Any?) {
        Shelf.clear()
        statusLeft.stringValue = "Shelf cleared"
    }

    @objc func menuShowTransfers(_ sender: Any?) {
        TransferPanelController.shared.show()
    }

    @objc func menuToggleMetadataColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let field = MetadataField(rawValue: raw) else { return }
        MetadataColumns.toggle(field)
        for pane in panes {
            for tab in pane.tabs where tab.isViewLoaded { tab.rebuildMetadataColumns() }
        }
        statusLeft.stringValue = MetadataColumns.enabled.isEmpty
            ? "No extra columns"
            : "Columns: " + MetadataColumns.enabled.map(\.title).joined(separator: ", ")
    }

    /// Built fresh each time so the ticks reflect what is on.
    static func metadataColumnMenu() -> NSMenu {
        let menu = NSMenu()
        let enabled = Set(MetadataColumns.enabled)
        for field in MetadataField.allCases {
            let item = NSMenuItem(title: field.title,
                                  action: #selector(menuToggleMetadataColumn(_:)), keyEquivalent: "")
            item.representedObject = field.rawValue
            item.state = enabled.contains(field) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func menuFitColumns(_ sender: Any?) {
        focusedList?.fitColumnsToContent()
    }

    @objc func menuToggleAutoFitColumns(_ sender: Any?) {
        Prefs.autoFitColumns.toggle()
        if Prefs.autoFitColumns { focusedList?.fitColumnsToContent() }
        statusLeft.stringValue = Prefs.autoFitColumns
            ? "Columns fit their content automatically"
            : "Column widths are manual"
    }

    @objc func menuToggleFolderTree(_ sender: Any?) {
        Prefs.showFolderTree.toggle()
        sidebar.rebuild()
        statusLeft.stringValue = Prefs.showFolderTree ? "Folder tree shown" : "Folder tree hidden"
    }

    @objc func menuToggleGitStatus(_ sender: Any?) {
        Prefs.showGitStatus.toggle()
        GitStatusReader.shared.invalidate()
        for pane in panes {
            pane.refreshToolbar()
            for tab in pane.tabs { tab.reload() }
        }
        propagateViewSettings()
    }

    /// View settings are global, so every open tab adopts them at once.
    private func propagateViewSettings() {
        for pane in panes {
            pane.refreshToolbar()
            pane.applyViewMode()
            for tab in pane.tabs where tab.isViewLoaded { tab.adoptGlobalViewSettings() }
        }
    }

    // MARK: - Search

    @objc func menuFindByName(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        searchController.present(for: self, mode: .name, root: url)
    }

    /// Search by meaning. Needs the folder to have been indexed; if it has
    /// not been, offers to do that rather than returning nothing.
    @objc func menuFindByMeaning(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        // Compared as a path: ~/Documents-old is not inside ~/Documents, but it
        // does start with it, so it was judged already indexed and the search
        // came back empty with nothing offering to fix it.
        let indexed = SemanticIndex.roots.contains {
            SemanticIndex.path(url.standardizedFileURL.path, isWithin: $0.standardizedFileURL.path)
        }
        guard indexed else {
            offerToIndex(url)
            return
        }
        searchController.present(for: self, mode: .meaning, root: url)
    }

    @objc func menuIndexFolder(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        SemanticIndex.addRoot(url)
        startIndexing()
    }

    @objc func menuRebuildIndex(_ sender: Any?) {
        SemanticIndex.shared.clear()
        startIndexing()
    }

    private func offerToIndex(_ url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Index “\(url.lastPathComponent)” to search it by meaning?"
        alert.informativeText = "Text files and PDFs in this folder are read once and turned "
            + "into a searchable form. It happens on this machine and nothing is sent anywhere. "
            + "Searching afterwards is instant."
        alert.addButton(withTitle: "Index")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            SemanticIndex.addRoot(url)
            self?.startIndexing()
        }
    }

    private func startIndexing() {
        statusLeft.stringValue = "Indexing…"
        SemanticIndex.shared.rebuild(progress: { [weak self] progress in
            self?.statusLeft.stringValue =
                "Indexing — \(progress.filesIndexed) file(s) read of \(progress.filesSeen) seen"
        }, finished: { [weak self] count in
            self?.statusLeft.stringValue = count == 0
                ? "Nothing readable to index here"
                : "Indexed \(SemanticIndex.shared.fileCount) file(s) — ⌃⌘F searches by meaning"
        })
    }

    @objc func menuFindInContents(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        searchController.present(for: self, mode: .contents, root: url)
    }

    /// Navigates the focused pane to a file's folder and selects it.
    /// Points the focused pane at a folder. Used for a folder handed over by
    /// the system — `reveal` would go to its parent and select it, which is
    /// not what double-clicking a folder means.
    func open(folder url: URL) {
        guard let list = focusedList else { return }
        list.navigate(to: url)
        list.focusTable()
    }

    func reveal(_ url: URL) {
        guard let list = focusedList else { return }
        list.navigate(to: url.deletingLastPathComponent())
        list.reload(selecting: url)
        list.focusTable()
    }

    @objc func menuSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func menuToggleKeyboardFirst(_ sender: Any?) {
        Prefs.keyboardFirst.toggle()
        statusLeft.stringValue = Prefs.keyboardFirst
            ? "Keyboard-first keys on — j k to move, h l to leave and enter"
            : "Keyboard-first keys off"
    }

    /// Opens a panel by name, for `SOQUEL_OPEN` and for the command palette's
    /// own tests.
    func openPanelNamed(_ name: String) {
        Log.info(.app, "Opening “\(name)” from SOQUEL_OPEN")
        // "settings:applications" opens that pane directly.
        let parts = name.lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        if parts.first == "settings" {
            SettingsWindowController.shared.show(pane: parts.count > 1 ? parts[1] : nil)
            return
        }

        switch name.lowercased() {
        case "diskmap": menuShowDiskMap(nil)
        case "shelf": menuShowShelf(nil)
        case "transfers": menuShowTransfers(nil)
        case "compare": menuCompareFolders(nil)
        case "search": menuFindByName(nil)
        case "meaning": menuFindByMeaning(nil)
        case "settings": menuSettings(nil)
        case "server": menuConnectToServer(nil)
        case "palette": menuCommandPalette(nil)
        default: Log.warn(.app, "No panel called “\(name)”")
        }
    }

    /// Puts the last few minutes of log on the clipboard, ready to paste into
    /// a bug report. No shortcut: it is a thing you go looking for.
    @objc func menuCopyRecentLogs(_ sender: Any?) {
        let text = Log.recent(minutes: 3)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.components(separatedBy: "\n").count
        statusLeft.stringValue = "Copied the last 3 minutes of log — \(lines) lines"
        Log.info(.app, "Copied \(lines) lines of log to the clipboard")
    }

    @objc func menuRevealLogs(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL(for: Date())])
    }

    @objc func menuShowThemes(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "themes")
    }

    @objc func menuRevealThemes(_ sender: Any?) {
        // One theme file, so this is the same thing as revealing theme.json.
        guard let url = try? Theme.writeTemplate() else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the settings file itself. Pending writes are flushed first, so the
    /// editor never opens a file that is one change behind the app.
    @objc func menuEditSettingsFile(_ sender: Any?) {
        Settings.writeNow()
        let url = Settings.url
        if let editor = ExternalApps.preferredEditor() {
            ExternalApps.open([url], in: editor) { _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func menuRevealSettingsFile(_ sender: Any?) {
        Settings.writeNow()
        NSWorkspace.shared.activateFileViewerSelecting([Settings.url])
    }

    // MARK: - Path commands

    @objc func menuCopyPath(_ sender: NSMenuItem) {
        guard let list = focusedList else { return }
        let format = PathFormat.allCases.first { $0.title == sender.representedObject as? String } ?? .absolute
        copyToPasteboard(list.targetURLs(), format: format)
        statusLeft.stringValue = "Copied \(format.title.lowercased())"
    }

    @objc func menuCopyRelativePath(_ sender: Any?) {
        guard let list = focusedList else { return }
        let base = gitRoot(for: list.url) ?? list.url
        let text = list.targetURLs().map { relativePath(of: $0, from: base) }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        statusLeft.stringValue = "Copied path relative to \(base.lastPathComponent)"
    }

    // MARK: - Integrations

    @objc func menuOpenInTerminal(_ sender: Any?) {
        guard let url = focusedList?.url else { return }
        guard let terminal = ExternalApps.preferredTerminal() else {
            statusLeft.stringValue = "No terminal found"
            NSSound.beep()
            return
        }
        ExternalApps.open([url], in: terminal) { [weak self] error in
            guard let self else { return }
            if let error { self.focusedList?.showError(error) }
            else { self.statusLeft.stringValue = "Opened \(url.lastPathComponent) in \(terminal.name)" }
        }
    }

    /// Chooses a terminal for this launch and remembers it.
    @objc func menuOpenInTerminalWith(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              ExternalApps.terminals.contains(where: { $0.bundleID == bundleID })
        else { return }
        Prefs.terminalBundleID = bundleID
        menuOpenInTerminal(nil)
    }

    @objc func menuOpenInEditor(_ sender: Any?) {
        guard let list = focusedList else { return }
        guard let editor = ExternalApps.preferredEditor() else {
            statusLeft.stringValue = "No supported editor found"
            NSSound.beep()
            return
        }
        AppLaunchGuard.confirm(opening: list.targetURLs(), with: editor.url, in: window) { [weak self] in
            guard let self else { return }
            ExternalApps.open(list.targetURLs(), in: editor) { [weak self] error in
                guard let self else { return }
                if let error { self.focusedList?.showError(error) }
                else { self.statusLeft.stringValue = "Opened in \(editor.name)" }
            }
        }
    }

    @objc func menuOpenInEditorWith(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              ExternalApps.editors.contains(where: { $0.bundleID == bundleID })
        else { return }
        Prefs.editorBundleID = bundleID
        menuOpenInEditor(nil)
    }

    /// Built without a window, for the main menu. Items target the responder
    /// chain so whichever window is focused handles them.
    static func terminalPickerPlaceholder() -> NSMenu {
        let menu = NSMenu()
        for terminal in ExternalApps.installedTerminals {
            let item = NSMenuItem(title: terminal.name,
                                  action: #selector(menuOpenInTerminalWith(_:)), keyEquivalent: "")
            item.representedObject = terminal.bundleID
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No terminal found", action: nil, keyEquivalent: "") }
        return menu
    }

    static func editorPickerPlaceholder() -> NSMenu {
        let menu = NSMenu()
        for editor in ExternalApps.installedEditors {
            let item = NSMenuItem(title: editor.name,
                                  action: #selector(menuOpenInEditorWith(_:)), keyEquivalent: "")
            item.representedObject = editor.bundleID
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No editor found", action: nil, keyEquivalent: "") }
        return menu
    }

    /// Menu of every installed terminal, for the File menu and context menu.
    func installedTerminalsMenu() -> NSMenu {
        let menu = NSMenu()
        for terminal in ExternalApps.installedTerminals {
            let item = NSMenuItem(title: terminal.name, action: #selector(menuOpenInTerminalWith(_:)), keyEquivalent: "")
            item.representedObject = terminal.bundleID
            item.state = terminal.bundleID == ExternalApps.preferredTerminal()?.bundleID ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No terminal found", action: nil, keyEquivalent: "")
        }
        return menu
    }

    func installedEditorsMenu() -> NSMenu {
        let menu = NSMenu()
        for editor in ExternalApps.installedEditors {
            let item = NSMenuItem(title: editor.name, action: #selector(menuOpenInEditorWith(_:)), keyEquivalent: "")
            item.representedObject = editor.bundleID
            item.state = editor.bundleID == ExternalApps.preferredEditor()?.bundleID ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No editor found", action: nil, keyEquivalent: "")
        }
        return menu
    }

    @objc func menuCommandPalette(_ sender: Any?) {
        CommandPalette.shared.present(for: self)
    }

    // MARK: - Menu validation

    // MARK: - Split view constraints

    /// The floor for the sidebar|panes divider. A sidebar that is off has none:
    /// the width floor applies to a column in use, and applying it to a hidden
    /// one held the divider 140pt from the edge over a blank column.
    static func outerMinimumSidebarCoordinate(sidebarShown: Bool) -> CGFloat {
        sidebarShown ? minimumSidebarWidth : 0
    }

    /// The ceiling for the panes|inspector divider, in the same coordinates as
    /// the proposal. An inspector that is off may go to the trailing edge; the
    /// minimum width applied to a hidden one reserved 220pt of blank column.
    static func outerMaximumInspectorCoordinate(proposedMax: CGFloat, inspectorShown: Bool) -> CGFloat {
        inspectorShown ? proposedMax - minimumInspectorWidth : proposedMax
    }

    /// Whether `adjustSubviews` may change the width of one of the outer
    /// split's columns. The sidebar and the inspector hold their widths while
    /// they are on show and the panes absorb the rest; a hidden one has to be
    /// resizable, since pinning it is what kept its column on screen after it
    /// was switched off.
    static func outerColumnResizes(isFixedColumn: Bool, isHidden: Bool) -> Bool {
        !isFixedColumn || isHidden
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === outerSplit {
            // Divider 0 is sidebar|panes; divider 1 is panes|inspector.
            return index == 0
                ? Self.outerMinimumSidebarCoordinate(sidebarShown: !sidebar.view.isHidden)
                : proposedMin + Self.minimumPaneWidth
        }
        let minimum = splitView.isVertical ? Self.minimumPaneWidth : Self.minimumPaneHeight
        return proposedMin + minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === outerSplit {
            if index == 0 {
                // The sidebar never grows past this, and always leaves room for a pane.
                return min(Self.maximumSidebarWidth, max(Self.minimumSidebarWidth, proposedMax - Self.minimumPaneWidth))
            }
            return Self.outerMaximumInspectorCoordinate(
                proposedMax: proposedMax, inspectorShown: !inspector.isHidden
            )
        }
        let minimum = splitView.isVertical ? Self.minimumPaneWidth : Self.minimumPaneHeight
        return proposedMax - minimum
    }

    /// The window is sized after the controller builds its views, so the first
    /// resize is the earliest point at which the dividers can be placed.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !hasPositionedSplits, notification.object as? NSSplitView === outerSplit else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPositionedSplits else { return }
            self.applyDefaultSplitPositions()
        }
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard splitView === outerSplit else { return true }
        return Self.outerColumnResizes(
            isFixedColumn: view === sidebar.view || view === inspector,
            isHidden: view.isHidden
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuGoBack): return focusedList?.canGoBack ?? false
        case #selector(menuGoForward): return focusedList?.canGoForward ?? false
        case #selector(menuUndo), #selector(undo):
            item.title = UndoStack.shared.topLabel.map { "Undo \($0)" } ?? "Undo"
            return UndoStack.shared.canUndo
        case #selector(NSText.paste(_:)):
            return !FileClipboard.read().isEmpty
        case #selector(NSText.cut(_:)), #selector(NSText.copy(_:)):
            return !(focusedList?.selectedURLs().isEmpty ?? true)
        case #selector(menuClosePane), #selector(menuSwapPanes),
             #selector(menuMoveToOppositePane), #selector(menuCopyToOppositePane):
            return panes.count > 1
        case #selector(menuSplitVertically), #selector(menuSplitHorizontally):
            return panes.count < Self.maximumPanes
        case #selector(menuToggleHidden):
            item.state = Prefs.showHiddenFiles ? .on : .off
            return true
        case #selector(menuToggleFolderSizes):
            item.state = Prefs.calculateFolderSizes ? .on : .off
            return true
        case #selector(menuToggleFolderTree):
            item.state = Prefs.showFolderTree ? .on : .off
            return true
        case #selector(menuToggleInspector):
            item.state = Prefs.showInspector ? .on : .off
            return true
        case #selector(menuToggleKeyboardFirst):
            item.state = Prefs.keyboardFirst ? .on : .off
            return true
        case #selector(menuToggleAutoFitColumns):
            item.state = Prefs.autoFitColumns ? .on : .off
            return true
        case #selector(menuToggleFoldersFirst):
            item.state = Prefs.foldersFirst ? .on : .off
            return true
        case #selector(menuPasteFiles):
            return !FileClipboard.read().isEmpty
        default:
            return true
        }
    }

    // MARK: - Command palette support

    func runCommand(_ command: PaletteCommand) {
        command.run(self)
    }
}

// MARK: - Delegates

extension MainWindowController: PaneDelegate {
    func pane(_ pane: PaneViewController, openInOppositePane url: URL) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        if panes.count == 1 {
            split(vertical: true)
            focusedList?.navigate(to: url)
        } else {
            let target = panes[(index + 1) % panes.count]
            target.activeList?.navigate(to: url)
            focusPane(at: (index + 1) % panes.count)
        }
    }

    func paneDidFocus(_ pane: PaneViewController) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != focusedIndex else {
            updateWindowTitle()
            return
        }
        focusedIndex = index
        for (i, p) in panes.enumerated() { p.setFocused(i == index) }
        updateWindowTitle()
    }

    func pane(_ pane: PaneViewController, didReportStatus text: String) {
        guard pane === focusedPane else { return }
        statusLeft.stringValue = text
        updateShelfDestination()
        updateCommandDirectory()
    }

    /// The shelf delivers to whatever the focused pane is showing, so it
    /// follows navigation rather than remembering where it was opened.
    private func updateCommandDirectory() {
        guard CommandPanelController.shared.isWindowLoaded,
              CommandPanelController.shared.window?.isVisible == true else { return }
        CommandPanelController.shared.directory = focusedList?.url
    }

    private func updateShelfDestination() {
        guard ShelfPanelController.shared.isWindowLoaded,
              ShelfPanelController.shared.window?.isVisible == true else { return }
        ShelfPanelController.shared.destination = focusedList?.url
    }

    func pane(_ pane: PaneViewController, didChangeSelection urls: [URL]) {
        guard pane === focusedPane else { return }
        if Prefs.showInspector { inspector.show(urls) }
        syncBrowse(from: pane, selection: urls)
    }

    /// Shows the selected folder in the next pane along.
    ///
    /// Only a single folder does anything: a multiple selection has no one
    /// folder to show, and a file has none at all. Both leave the other pane
    /// where it is rather than clearing it.
    private func syncBrowse(from pane: PaneViewController, selection urls: [URL]) {
        guard Prefs.syncBrowsing, panes.count > 1,
              let index = panes.firstIndex(where: { $0 === pane }),
              let target = MainWindowController.syncTarget(for: urls)
        else { return }
        // The other pane is only being shown something; focus stays here, or
        // arrowing down a list would throw the keyboard across the window on
        // every row.
        panes[(index + 1) % panes.count].activeList?.navigate(to: target)
    }

    /// The folder a selection should show in the other pane, if any.
    static func syncTarget(for urls: [URL]) -> URL? {
        guard urls.count == 1, let url = urls.first else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }

    func paneDidChangeTabs(_ pane: PaneViewController) {
        updateWindowTitle()
        if pane === focusedPane, let url = pane.currentURL { sidebar.reveal(url) }
    }
}

extension MainWindowController: SidebarDelegate {
    func sidebar(_ sidebar: SidebarViewController, didSelect url: URL) {
        debugLog("sidebar didSelect \(url.path)")
        focusedList?.navigate(to: url)
    }

    func sidebar(_ sidebar: SidebarViewController, revealFile url: URL) {
        debugLog("sidebar revealFile \(url.path)")
        reveal(url)
    }

    func sidebar(_ sidebar: SidebarViewController, run search: SavedSearch) {
        // A search saved against a folder that has gone runs in the pane's
        // folder rather than failing.
        let fallback = focusedList?.url ?? FileManager.default.homeDirectoryForCurrentUser
        searchController.present(for: self, saved: search, fallbackRoot: fallback)
    }

    func sidebar(_ sidebar: SidebarViewController, openInNewTab url: URL) {
        focusedPane?.addTab(url: url)
    }
}

// MARK: - Git helpers

func gitRoot(for url: URL) -> URL? {
    let fm = FileManager.default
    var cursor: URL? = url.standardizedFileURL
    while let current = cursor {
        if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
        cursor = parentDirectoryURL(of: current)
    }
    return nil
}

func relativePath(of url: URL, from base: URL) -> String {
    let target = url.standardizedFileURL.pathComponents
    let root = base.standardizedFileURL.pathComponents
    var i = 0
    while i < target.count && i < root.count && target[i] == root[i] { i += 1 }
    let up = Array(repeating: "..", count: root.count - i)
    let down = Array(target[i...])
    let parts = up + down
    return parts.isEmpty ? "." : parts.joined(separator: "/")
}
