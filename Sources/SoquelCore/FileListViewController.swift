import AppKit
import Quartz

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, didNavigateTo url: URL)
    func fileList(_ list: FileListViewController, openInNewTab url: URL)
    func fileList(_ list: FileListViewController, openInOppositePane url: URL)
    func fileListDidRequestFocus(_ list: FileListViewController)
    func fileList(_ list: FileListViewController, didReportStatus text: String)
    func fileList(_ list: FileListViewController, didChangeSelection urls: [URL])
    /// The contents changed under the view — after a trash, a rename or a
    /// move — so anything drawing them from its own copy has to re-read.
    func fileListDidReload(_ list: FileListViewController)
    func fileListDidRequestSelectAllInColumns(_ list: FileListViewController)
    func fileListDidRequestInvertSelectionInColumns(_ list: FileListViewController)
    /// "/" puts the caret in the pane's filter box. The list used to own a
    /// second one of its own, so the window showed two identical fields.
    func fileListDidRequestFilter(_ list: FileListViewController)
    /// Returns true when the column browser found a match, so a keystroke that
    /// did something is not also passed on.
    func fileList(_ list: FileListViewController, typeSelectInColumns prefix: String) -> Bool
    /// Puts a rename editor over the name in the column browser. Returns false
    /// when the file is not on screen there, so the caller can fall back.
    func fileList(_ list: FileListViewController, renameInColumns url: URL) -> Bool
}

/// Table subclass that routes navigation and single-key commands before
/// NSTableView's own arrow/type-select handling.
final class FileTableView: NSTableView {
    weak var commandTarget: FileListViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if commandTarget?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// Right-clicking an unselected row selects it first, so context-menu
    /// actions always act on what the user pointed at.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return commandTarget?.contextMenu(forRow: row)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { commandTarget?.didBecomeFocused() }
        return ok
    }

    /// A table refuses to hand first responder to a control unless a double
    /// click asked for it, and `editColumn(_:row:with:select:)` passes no event
    /// at all. Return renamed nothing for exactly that reason: the editor was
    /// asked for and declined. The name field is the only editable control in a
    /// row, so allowing it is enough.
    override func validateProposedFirstResponder(
        _ responder: NSResponder, for event: NSEvent?
    ) -> Bool {
        if let field = responder as? NSTextField, field.isEditable { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class FileListViewController: NSViewController, NSTextFieldDelegate, NSSearchFieldDelegate {
    weak var delegate: FileListDelegate?

    private(set) var url: URL
    private(set) var allItems: [FileItem] = []
    private(set) var items: [FileItem] = []

    private var back: [URL] = []
    private var forward: [URL] = []

    private var sortOrder = Prefs.sortOrder
    private var gitStatuses: [String: GitState] = [:]
    private var gitRootURL: URL?
    private let loader = DirectoryLoader()
    private var watcher: DirectoryWatcher?
    private var refreshPending = false

    private var filterText = "" {
        didSet { applyFilterAndSort(preservingSelection: true) }
    }

    private var tableView: FileTableView!
    private var scrollView: NSScrollView!
    private var filterBar: NSView!
    /// Hiding a view does not collapse it in Auto Layout: its constraints still
    /// hold, so the bar went on reserving its height and left a band of empty
    /// space above the list in every window. The height is driven explicitly.
    private var filterBarHeight: NSLayoutConstraint!
    static let filterBarHeight: CGFloat = 30
    private var filterField: NSSearchField!
    private var emptyLabel: NSTextField!

    private var backgroundView: BackgroundImageView!
    private var collectionView: FileCollectionView!
    private var collectionScroll: NSScrollView!
    /// What this list is actually showing. The one source of truth: the global
    /// Prefs.viewMode is a default, and a list can be showing something else
    /// while a change propagates or a folder remembers its own.
    private(set) var mode: ViewMode = Prefs.viewMode
    private var isIconMode: Bool { mode == .icon }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - View construction

    override func loadView() {
        let container = NSView()

        filterField = NSSearchField()
        filterField.placeholderString = "Filter this folder"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false

        filterBar = NSView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(filterField)
        setFilterBarVisible(false)

        tableView = FileTableView()
        tableView.commandTarget = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        // Alternating rows and selection are drawn by FileRowView so they follow
        // the theme instead of the system slab highlight.
        tableView.usesAlternatingRowBackgroundColors = false
        // .inset adds a wide margin of its own down both sides, which on a file
        // list is a stripe of nothing before every icon.
        tableView.style = .plain
        tableView.rowHeight = Theme.rowHeight
        tableView.intercellSpacing = NSSize(width: 4, height: 0)
        tableView.doubleAction = #selector(openSelection)
        tableView.target = self
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setAccessibilityLabel("Files in \(url.lastPathComponent)")
        filterField.setAccessibilityLabel("Filter files in this folder")

        for column in Self.defaultColumns {
            addColumn(column.id, column.title, width: column.width, min: column.min)
        }
        updateSortIndicators()
        applyColumnVisibility()
        rebuildMetadataColumns()

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // A sunken well around the list, which is how a nineties file pane was
        // set into the window rather than floating on it.
        scrollView.borderType = Theme.style == .bevelled ? .bezelBorder : .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView = FileCollectionView()
        collectionView.commandTarget = self
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collectionView.setAccessibilityLabel("Files in \(url.lastPathComponent)")
        // The icon view had drag out but no drop in, so files could leave it
        // and never land on it.
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.registerForDraggedTypes([.fileURL])

        collectionScroll = NSScrollView()
        collectionScroll.documentView = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.autohidesScrollers = true
        collectionScroll.drawsBackground = false
        collectionScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        backgroundView = BackgroundImageView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        // Added first so it sits behind the listing. The scroll views stop
        // drawing their own background so the image shows through.
        container.addSubview(backgroundView)
        container.addSubview(filterBar)
        container.addSubview(scrollView)
        container.addSubview(collectionScroll)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            filterBar.topAnchor.constraint(equalTo: container.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterField.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: -8),
            filterField.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            collectionScroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        // Zero while hidden, so the list starts directly under the path bar.
        filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterBarHeight.isActive = true

        view = container
        applyViewMode()
        applyBackground()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if allItems.isEmpty { reload() }
        focusTable()
    }

    // MARK: - View mode

    /// Brings `mode` up to date without needing the view to exist.
    ///
    /// applyViewMode() cannot do this on its own: it returns early for a list
    /// whose view has never loaded, and the pane asks the list what mode it is
    /// in before the list has been told. That left the pane hiding the column
    /// browser while the list hid its own table, and the pane drew nothing at
    /// all.
    func refreshMode() {
        mode = FolderViewSettings.viewMode(for: url)
    }

    func applyViewMode() {
        refreshMode()
        guard isViewLoaded else { return }
        scrollView.isHidden = mode != .list
        collectionScroll.isHidden = mode != .icon
        if mode == .column { return }

        if isIconMode {
            let side = CGFloat(Prefs.iconSize)
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: side, height: side + 34)
            }
            collectionView.reloadData()
            restoreCollectionSelection(selectedURLsCache)
        } else {
            tableView.reloadData()
        }
    }

    /// Selection is held as URLs so it survives switching view modes, where the
    /// index of an item means nothing to the other view.
    private var selectedURLsCache: [URL] = []

    /// The columns a list starts with, in the order they are added.
    ///
    /// Git is first and has no text, so anything that wants the name has to ask
    /// for it by identifier rather than assuming column zero.
    static let defaultColumns: [(id: String, title: String, width: CGFloat, min: CGFloat)] = [
        ("git", "", 22, 22),
        ("name", "Name", 200, 140),
        ("ext", "Ext", 60, 48),
        ("size", "Size", 90, 70),
        ("kind", "Kind", 120, 90),
        ("modified", "Date Modified", 160, 130),
        ("created", "Date Created", 160, 130),
    ]

    private func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.maxWidth = 900
        // Without userResizingMask a column only ever resizes with the table,
        // so the divider between headers does nothing when dragged.
        column.resizingMask = [.userResizingMask, .autoresizingMask]
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        if let saved = Self.savedWidth(for: id) {
            column.width = Swift.max(Swift.min(saved, column.maxWidth), column.minWidth)
        }
        tableView.addTableColumn(column)
    }

    // MARK: - Column widths

    private static let widthsKey = "columnWidths"

    static func savedWidth(for id: String) -> CGFloat? {
        guard let table = Settings.object(forKey: widthsKey) as? [String: Double],
              let value = table[id]
        else { return nil }
        return CGFloat(value)
    }

    static func saveWidth(_ width: CGFloat, for id: String) {
        var table = (Settings.object(forKey: widthsKey) as? [String: Double]) ?? [:]
        table[id] = Double(width)
        Settings.set(table, forKey: widthsKey)
    }

    /// A dragged column stays where it was put.
    ///
    /// Fitting to content on every reload would undo the drag on the next
    /// keystroke, so dragging one turns the automatic fitting off and says so
    /// rather than quietly fighting the user for the width.
    @objc func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              view.window?.isKeyWindow == true
        else { return }
        let floor = column.minWidth
        if column.width < floor {
            column.width = floor
            return
        }
        Self.saveWidth(column.width, for: column.identifier.rawValue)

        if Prefs.autoFitColumns {
            Prefs.autoFitColumns = false
            delegate?.fileList(self, didReportStatus:
                "Column widths are yours now — automatic fitting is off")
        }
    }

    // MARK: - Navigation

    func navigate(to newURL: URL, recordHistory: Bool = true) {
        // Resolve symlinks so the pane's URL matches the paths that directory
        // enumeration returns; /tmp and /private/tmp must not read as two places.
        let standardized = newURL.resolvingSymlinksInPath().standardizedFileURL
        guard standardized != url || allItems.isEmpty else { return }
        if recordHistory {
            back.append(url)
            forward.removeAll()
        }
        url = standardized
        filterText = ""
        filterField.stringValue = ""
        setFilterBarVisible(false)
        // The column browser is rebuilt for the new folder, so whatever it had
        // selected no longer exists as far as the commands are concerned.
        columnSelection = []
        // The folder decides how it is shown, when it has an opinion recorded.
        if FolderViewSettings.isEnabled {
            sortOrder = FolderViewSettings.sortOrder(for: url)
            updateSortIndicators()
            applyViewMode()
        }
        delegate?.fileList(self, didNavigateTo: url)
        reload(selecting: nil, resetScroll: true)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(url)
        let leaving = url
        url = previous
        delegate?.fileList(self, didNavigateTo: url)
        reload(selecting: leaving, resetScroll: true)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(url)
        url = next
        delegate?.fileList(self, didNavigateTo: url)
        reload(selecting: nil, resetScroll: true)
    }

    func goUp() {
        guard let parent = parentDirectoryURL(of: url) else { return }
        let leaving = url
        back.append(url)
        forward.removeAll()
        url = parent
        delegate?.fileList(self, didNavigateTo: url)
        reload(selecting: leaving, resetScroll: true)
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    // MARK: - Loading

    /// - Parameters:
    ///   - selecting: URL to select once loaded, used when returning to a parent.
    ///   - completion: runs after the listing is on screen. Callers that need to
    ///     touch rows must use this; the load is asynchronous, so anything done
    ///     straight after `reload()` acts on the previous contents.
    func reload(selecting: URL? = nil, resetScroll: Bool = false, completion: (() -> Void)? = nil) {
        // Background tabs from a restored session have no views yet; they load
        // their contents when they first appear.
        guard isViewLoaded else { completion?(); return }
        let previousSelection = selecting.map { [$0] } ?? selectedURLs()
        let watchedURL = url
        DirectoryWatcher.make(url: watchedURL) { [weak self] in
            self?.scheduleRefresh()
        } ready: { [weak self] made in
            // Navigation may have moved on while the directory was being opened.
            guard let self, self.url == watchedURL else { return }
            self.watcher = made
        }

        loader.load(url, showHidden: Prefs.showHiddenFiles) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let loaded):
                self.allItems = loaded
                self.applyFilterAndSort(preservingSelection: false)
                self.restoreSelection(previousSelection)
                self.delegate?.fileListDidReload(self)
                if resetScroll, self.tableView.numberOfRows > 0 {
                    self.tableView.scrollRowToVisible(self.tableView.selectedRow >= 0 ? self.tableView.selectedRow : 0)
                }
                self.emptyLabel.isHidden = !self.items.isEmpty
                self.emptyLabel.stringValue = self.allItems.isEmpty
                    ? Self.emptyMessage(for: self.url)
                    : "No items match the filter"
            case .failure(let error):
                self.allItems = []
                self.items = []
                self.tableView.reloadData()
                self.emptyLabel.isHidden = false
                self.emptyLabel.stringValue = error.localizedDescription
            }
            self.refreshGitStatus()
            self.measureFolderSizes()
            self.requestMetadata()
            if Prefs.autoFitColumns { self.fitColumnsToContent() }
            self.reportStatus()
            completion?()
        }
    }

    /// macOS hands a sandboxed-out app an empty listing rather than an error
    /// for Desktop, Documents, and Downloads, so an empty result in one of
    /// those folders is ambiguous. Say so instead of asserting it is empty.
    static func emptyMessage(for url: URL) -> String {
        guard isPrivacyProtected(url) else { return "This folder is empty" }
        return """
        This folder is empty, or macOS is blocking access to it.
        Grant Soquel Full Disk Access in System Settings › Privacy & Security to be sure.
        """
    }

    /// The locations macOS gates behind an explicit grant.
    static func isPrivacyProtected(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let gated = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { home + "/" + $0 }
        if gated.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return path.hasPrefix("/Volumes/") && path != "/Volumes"
    }

    /// Filesystem events can arrive in bursts; collapse them into one reload.
    /// A refresh that lands mid-rename is deferred, not dropped — otherwise the
    /// listing stays stale until the next unrelated change.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            // A reload under an open editor would pull the row out from under it.
            if self.renameEditor.isEditing {
                self.scheduleRefresh()
                return
            }
            self.reload()
        }
    }

    private func applyFilterAndSort(preservingSelection: Bool) {
        let previous = preservingSelection ? selectedURLs() : []
        var visible = allItems
        if !filterText.isEmpty {
            let needle = filterText.lowercased()
            visible = visible.filter { $0.name.lowercased().contains(needle) }
        }
        items = sortItems(visible, order: sortOrder, foldersFirst: Prefs.foldersFirst)
        tableView.reloadData()
        if isIconMode { collectionView.reloadData() }
        if preservingSelection { restoreSelection(previous) }
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty && !allItems.isEmpty {
            emptyLabel.stringValue = "No items match the filter"
        }
        reportStatus()
    }

    private func restoreSelection(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wanted = Set(urls)
        var indexes = IndexSet()
        for (i, item) in items.enumerated() where wanted.contains(item.url) {
            indexes.insert(i)
        }
        if !indexes.isEmpty {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if let first = indexes.first { tableView.scrollRowToVisible(first) }
        }
        selectedURLsCache = urls
        restoreCollectionSelection(urls)
    }

    /// Says how to back out, for as long as a drag is under way.
    ///
    /// AppKit cancels a drag when Escape is pressed, but nothing says so
    /// anywhere, so a drag picked up by accident has to be carried back to
    /// where it started. `reportStatus` puts the ordinary line back when the
    /// drag ends, however it ends.
    private func reportDragHint(count: Int) {
        delegate?.fileList(self, didReportStatus:
            "Dragging \(count) item\(count == 1 ? "" : "s") — press esc to cancel")
    }

    private func reportStatus() {
        delegate?.fileList(self, didChangeSelection: selectedURLs())
        let selected = selectedURLs().count
        var text = "\(items.count) item\(items.count == 1 ? "" : "s")"
        if !filterText.isEmpty { text += " of \(allItems.count)" }
        if selected > 0 {
            text += " · \(selected) selected"
            let bytes = selectedItems.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            if bytes > 0 { text += " (\(Self.byteFormatter.string(fromByteCount: bytes)))" }
        }
        delegate?.fileList(self, didReportStatus: text)
    }

    /// Folder sizes are opt-in and measured one folder at a time in the
    /// background; the column shows an ellipsis until an answer arrives.
    private func measureFolderSizes() {
        guard Prefs.calculateFolderSizes else { return }
        FolderSizeCalculator.shared.onUpdate = { [weak self] url, _ in
            guard let self, self.isViewLoaded else { return }
            guard let row = self.items.firstIndex(where: { $0.url == url }) else { return }
            let column = self.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
            guard column >= 0 else { return }
            self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
        }
        for item in items where item.opensAsFolder {
            FolderSizeCalculator.shared.measure(item.url)
        }
    }

    /// Git status is Tier 3 metadata: the listing is already on screen before
    /// this runs, and a repository that cannot be read simply shows nothing.
    private func refreshGitStatus() {
        guard Prefs.showGitStatus else {
            gitStatuses = [:]
            gitRootURL = nil
            return
        }
        GitStatusReader.shared.status(for: url) { [weak self] statuses, root in
            guard let self else { return }
            self.gitStatuses = statuses
            self.gitRootURL = root
            if self.isViewLoaded { self.tableView.reloadData() }
        }
    }

    /// The repository containing this folder, when there is one.
    var repositoryRoot: URL? { gitRootURL }

    func didBecomeFocused() {
        delegate?.fileListDidRequestFocus(self)
        // Hand an open Quick Look panel to this list, otherwise it keeps
        // previewing the pane the user just left.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().updateController()
        }
    }

    // MARK: - Selection accessors

    func selectedURLs() -> [URL] {
        // In column view the browser owns the selection and the table is not on
        // screen, so its rows say nothing about what the user picked.
        if mode == .column { return columnSelection }
        if isIconMode {
            return collectionView.selectionIndexPaths
                .compactMap { items.indices.contains($0.item) ? items[$0.item].url : nil }
        }
        return tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    /// What the column browser currently has selected, mirrored here so every
    /// command acts on it without knowing which view is on screen.
    private(set) var columnSelection: [URL] = []

    func setColumnSelection(_ urls: [URL]) {
        columnSelection = urls
    }

    private var selectedItems: [FileItem] {
        let urls = Set(selectedURLs())
        return items.filter { urls.contains($0.url) }
    }

    /// URLs the commands should act on: the selection, or the folder itself
    /// when nothing is selected.
    func targetURLs() -> [URL] {
        let selected = selectedURLs()
        return selected.isEmpty ? [url] : selected
    }

    func focusTable() {
        view.window?.makeFirstResponder(isIconMode ? collectionView : tableView)
    }

    // MARK: - Keyboard-first preset

    /// Set by a bare `g`, cleared by the next keypress or by the timeout.
    /// What has been typed so far to jump to a name, and when the last key
    /// arrived. Matches the interval AppKit uses for NSTableView's own
    /// type-select, so the two views feel the same.
    private var typeSelectBuffer = ""
    private var typeSelectLastKey: Date?
    static let typeSelectTimeout: TimeInterval = 1.0

    private var pendingG = false
    private var pendingGExpiry: Date?

    /// Handles a keypress under the vi-style preset. Returns false when the
    /// key means nothing here, so ordinary handling continues.
    private func handleKeyboardFirst(_ event: NSEvent) -> Bool {
        guard Prefs.keyboardFirst, let characters = event.charactersIgnoringModifiers else { return false }

        let stillPending = pendingG && (pendingGExpiry.map { $0 > Date() } ?? false)
        guard let action = KeyboardFirst.action(
            forCharacters: characters, modifiers: event.modifierFlags, pendingG: stillPending
        ) else {
            pendingG = false
            return false
        }

        if action == .awaitingSecondG {
            pendingG = true
            pendingGExpiry = Date().addingTimeInterval(KeyboardFirst.sequenceTimeout)
            return true
        }
        pendingG = false

        switch action {
        case .moveDown: moveSelection(by: 1, extending: false)
        case .moveUp: moveSelection(by: -1, extending: false)
        case .extendDown: moveSelection(by: 1, extending: true)
        case .extendUp: moveSelection(by: -1, extending: true)
        case .halfPageDown: moveSelection(by: halfPage, extending: false)
        case .halfPageUp: moveSelection(by: -halfPage, extending: false)
        case .moveToTop: selectFirstRow()
        case .moveToBottom: selectLastRow()
        case .goToParent: goUp()
        case .openSelection: openSelection()
        case .goBack: goBack()
        case .goForward: goForward()
        case .beginFilter: beginFilter()
        case .clearSelection, .awaitingSecondG: break
        }
        return true
    }

    /// Half the visible rows, so ⌃d moves by what is on screen rather than a
    /// fixed count that is wrong at every other window size.
    private var halfPage: Int {
        let height = isIconMode ? collectionView.visibleRect.height : tableView.visibleRect.height
        return max(1, Int(height / max(Theme.rowHeight, 1)) / 2)
    }

    private func moveSelection(by delta: Int, extending: Bool) {
        guard !items.isEmpty else { return }
        if isIconMode {
            let current = collectionView.selectionIndexPaths.map(\.item).max() ?? -1
            let target = min(max(current + delta, 0), items.count - 1)
            collectionView.selectionIndexPaths = [IndexPath(item: target, section: 0)]
            collectionView.scrollToItems(
                at: [IndexPath(item: target, section: 0)], scrollPosition: .nearestHorizontalEdge
            )
            collectionSelectionChanged()
            return
        }
        let current = delta > 0
            ? (tableView.selectedRowIndexes.max() ?? -1)
            : (tableView.selectedRowIndexes.min() ?? items.count)
        let target = min(max(current + delta, 0), items.count - 1)
        if extending {
            tableView.selectRowIndexes([target], byExtendingSelection: true)
        } else {
            tableView.selectRowIndexes([target], byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(target)
    }

    func selectLastRow() {
        guard !items.isEmpty else { return }
        let last = items.count - 1
        if isIconMode {
            collectionView.selectionIndexPaths = [IndexPath(item: last, section: 0)]
            collectionView.scrollToItems(
                at: [IndexPath(item: last, section: 0)], scrollPosition: .nearestHorizontalEdge
            )
            collectionSelectionChanged()
        } else {
            tableView.selectRowIndexes([last], byExtendingSelection: false)
            tableView.scrollRowToVisible(last)
        }
    }

    /// Shows or hides the filter bar, collapsing its height so a hidden bar
    /// takes no room.
    private func setFilterBarVisible(_ visible: Bool) {
        guard filterBar != nil else { return }
        filterBar.isHidden = !visible
        filterBarHeight?.constant = visible ? Self.filterBarHeight : 0
    }

    func selectFirstRow() {
        guard !items.isEmpty else { return }
        if isIconMode {
            collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
            collectionSelectionChanged()
        } else {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func restoreCollectionSelection(_ urls: [URL]) {
        guard isIconMode, !urls.isEmpty else { return }
        let wanted = Set(urls)
        let paths = items.enumerated()
            .filter { wanted.contains($0.element.url) }
            .map { IndexPath(item: $0.offset, section: 0) }
        collectionView.selectionIndexPaths = Set(paths)
    }

    func collectionSelectionChanged() {
        selectedURLsCache = selectedURLs()
        reportStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: - Keyboard

    /// Returns true when the event was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // The preset runs first: under it a letter is a command, not the start
        // of a type-select.
        if handleKeyboardFirst(event) { return true }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let plain = flags.subtracting([.function, .numericPad]).isEmpty

        switch event.keyCode {
        case 36, 76: // Return, Enter — renames, as in Finder. ⌘↓ or ⌘O opens.
            if plain { beginRename(); return true }
            return false
        case 49: // Space
            if plain { toggleQuickLook(); return true }
            return false
        case 51: // Delete
            if plain {
                if selectedURLs().isEmpty { goUp() } else { trashSelection() }
                return true
            }
            if flags == [.command] { trashSelection(); return true }
            if flags == [.command, .option] { deleteSelectionPermanently(); return true }
            return false
        case 125: // Down arrow
            if hasCommand { openSelection(); return true }
            return false
        case 126: // Up arrow
            if hasCommand { goUp(); return true }
            return false
        case 123: // Left arrow
            if hasCommand { goBack(); return true }
            return false
        case 124: // Right arrow
            if hasCommand { goForward(); return true }
            return false
        default:
            break
        }

        if plain, event.charactersIgnoringModifiers == "/" {
            beginFilter()
            return true
        }

        // Typing a name jumps to it. NSTableView does this for itself, but the
        // icon, tree and column views do not, so it is done here for all of
        // them — the same keys have to mean the same thing in every view.
        if plain || flags == [.shift], let typed = event.charactersIgnoringModifiers,
           typed.count == 1, let scalar = typed.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar),
           !CharacterSet.whitespaces.contains(scalar) {
            return typeSelect(typed)
        }
        return false
    }

    // MARK: - Type to select

    /// Selects the first item whose name begins with what has been typed.
    ///
    /// Successive keystrokes build up a prefix, as in Finder: "re", "rep" and
    /// so on. The buffer is dropped after a pause, so a later unrelated letter
    /// starts a fresh search rather than extending a stale one. Typing the same
    /// letter repeatedly cycles through the items starting with it, which is
    /// what that gesture means everywhere else.
    private func typeSelect(_ character: String) -> Bool {
        guard !items.isEmpty else { return false }
        let now = Date()
        if let last = typeSelectLastKey, now.timeIntervalSince(last) > Self.typeSelectTimeout {
            typeSelectBuffer = ""
        }
        typeSelectLastKey = now

        let repeatingSameLetter = !typeSelectBuffer.isEmpty
            && typeSelectBuffer.allSatisfy { String($0).caseInsensitiveCompare(character) == .orderedSame }
        let prefix = repeatingSameLetter ? character : typeSelectBuffer + character
        typeSelectBuffer = repeatingSameLetter ? typeSelectBuffer + character : prefix

        // Cycling starts looking after the current row; a growing prefix starts
        // from the top so it cannot skip past the answer.
        let current = selectedIndex()
        let start = repeatingSameLetter && current >= 0 ? current + 1 : 0
        let order = (0..<items.count).map { (start + $0) % items.count }

        // In column view the table is off screen, so the visible column is
        // what has to move.
        if mode == .column {
            if delegate?.fileList(self, typeSelectInColumns: prefix) != true { NSSound.beep() }
            return true
        }

        guard let match = order.first(where: {
            items[$0].name.lowercased().hasPrefix(prefix.lowercased())
        }) else {
            NSSound.beep()
            return true     // swallowed: a letter with no match must not fall through
        }
        select(index: match)
        return true
    }

    private func selectedIndex() -> Int {
        isIconMode
            ? (collectionView.selectionIndexPaths.first?.item ?? -1)
            : tableView.selectedRow
    }

    private func select(index: Int) {
        if isIconMode {
            let path = IndexPath(item: index, section: 0)
            collectionView.selectionIndexPaths = [path]
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            collectionSelectionChanged()
        } else {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    // MARK: - Commands

    @objc func openSelection() {
        let selected = selectedItems
        Log.debug(.ui, "openSelection: mode=\(mode.rawValue) selected=\(selected.count) "
            + "rows=\(tableView.selectedRowIndexes.count) column=\(columnSelection.count)")
        guard !selected.isEmpty else {
            delegate?.fileList(self, didReportStatus: "Nothing selected to open")
            return
        }
        if selected.count == 1, selected[0].opensAsFolder {
            navigate(to: selected[0].url.resolvingSymlinksInPath())
            return
        }

        let folders = selected.filter(\.opensAsFolder)
        let files = selected.filter { !$0.opensAsFolder }.map(\.url)
        for folder in folders {
            delegate?.fileList(self, openInNewTab: folder.url.resolvingSymlinksInPath())
        }
        guard !files.isEmpty else { return }

        // Asked once for the whole selection rather than once per file, and
        // only when the application is one of the slow ones.
        AppLaunchGuard.confirm(opening: files, with: nil, in: view.window) {
            for file in files { NSWorkspace.shared.open(file) }
        }
    }

    /// Opens the bundle in a window over this one. A double-click still
    /// launches the application — looking inside is the deliberate act, and
    /// making it the default would mean nothing in the folder starts any more.
    @objc func showPackageContents() {
        guard let item = selectedItems.first, PackageContents.canInspect(item) else { return }
        PackageContentsController.show(item.url, over: view.window) { [weak self] folder in
            guard let self else { return }
            self.delegate?.fileList(self, openInNewTab: folder)
        }
    }

    /// Finds what the application left around the system and shows it for
    /// review. Nothing is deleted without ticking it first.
    @objc func uninstallApp() {
        guard let item = selectedItems.first, item.url.pathExtension == "app" else { return }
        UninstallPanelController.show(item.url, over: view.window) { [weak self] in
            self?.reload()
        }
    }

    /// Zips the selection beside itself, without the macOS litter.
    @objc func compressSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        delegate?.fileList(self, didReportStatus: "Compressing \(urls.count) item(s)…")

        Archiver.compress(urls) { [weak self] outcome in
            guard let self else { return }
            self.delegate?.fileList(self, didReportStatus: outcome.message)
            self.reload(selecting: outcome.archive)
        }
    }

    /// The Tags submenu. A tick means every selected file already has it.
    private func tagsMenuItem() -> NSMenuItem {
        let urls = selectedURLs()
        let submenu = NSMenu()
        let shared = Set(urls.map { Set(Tags.read($0)) }.reduce(Set<String>()) {
            $0.isEmpty ? $1 : $0.intersection($1)
        })

        for (name, colour) in Tags.standard {
            let item = NSMenuItem(title: name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.representedObject = name
            item.target = self
            item.state = shared.contains(name) ? .on : .off
            item.image = Self.swatch(colour)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Tags", action: #selector(clearTags), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)

        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func swatch(_ colour: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let urls = selectedURLs()
        guard let first = urls.first else { return }

        // Warn once, before anything is written, rather than per file.
        if let warning = Tags.warning(for: first) {
            let alert = NSAlert()
            alert.messageText = "This disk cannot keep tags"
            alert.informativeText = warning
            alert.addButton(withTitle: "Tag Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        var failed = 0
        for url in urls where Tags.toggle(name, on: url) != nil { failed += 1 }
        delegate?.fileList(self, didReportStatus: failed == 0
            ? "Tagged \(urls.count) item(s) \(name)"
            : "Could not tag \(failed) of \(urls.count) item(s)")
        reload(selecting: urls.first)
    }

    @objc private func clearTags() {
        let urls = selectedURLs()
        for url in urls { Tags.write([], to: url) }
        delegate?.fileList(self, didReportStatus: "Cleared tags on \(urls.count) item(s)")
        reload(selecting: urls.first)
    }

    /// Makes a symlink beside each selected item. Finder's Make Alias makes an
    /// alias, which the shell cannot follow.
    @objc func makeSymlink() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        var created: [URL] = []
        var failed: [String] = []

        for target in urls {
            let name = Self.symlinkName(for: target, in: url)
            do {
                created.append(try OperationEngine.shared.createSymlink(to: target, in: url, named: name))
            } catch {
                failed.append(target.lastPathComponent)
            }
        }

        if !created.isEmpty { UndoStack.shared.pushCreated(created, label: "Make Symlink") }
        delegate?.fileList(self, didReportStatus: Self.symlinkStatus(created: created, failed: failed))
        reload(selecting: created.first)
    }

    /// "name symlink", then " 2", " 3"… A symlink named after the file it
    /// points at would collide with it whenever both live in one folder.
    static func symlinkName(for target: URL, in directory: URL) -> String {
        let base = target.lastPathComponent + " symlink"
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path
        ) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    static func symlinkStatus(created: [URL], failed: [String]) -> String {
        switch (created.count, failed.count) {
        case (0, 0): return "Nothing to link"
        case (let made, 0): return made == 1 ? "Made 1 symlink" : "Made \(made) symlinks"
        case (0, let bad): return bad == 1 ? "Could not link \(failed[0])" : "Could not link \(bad) items"
        case (let made, let bad): return "Made \(made) symlinks, \(bad) failed"
        }
    }

    @objc func openInNewTabAction() {
        for item in selectedItems where item.opensAsFolder {
            delegate?.fileList(self, openInNewTab: item.url.resolvingSymlinksInPath())
        }
    }

    @objc func openInOppositePaneAction() {
        guard let item = selectedItems.first(where: { $0.opensAsFolder }) else { return }
        delegate?.fileList(self, openInOppositePane: item.url.resolvingSymlinksInPath())
    }

    @objc func openWithDefaultApp() {
        for url in selectedURLs() { NSWorkspace.shared.open(url) }
    }

    @objc func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targetURLs())
    }

    /// Driven by the pane's filter field, which now lives above the toolbar.
    func setFilter(_ text: String) {
        filterText = text
    }

    func beginFilter() {
        delegate?.fileListDidRequestFilter(self)
    }

    @objc private func filterChanged() {
        filterText = filterField.stringValue
        if filterText.isEmpty && view.window?.firstResponder != filterField.currentEditor() {
            setFilterBarVisible(false)
        }
    }

    func endFilter() {
        filterField.stringValue = ""
        filterText = ""
        setFilterBarVisible(false)
        focusTable()
    }

    @objc func toggleQuickLook() {
        // Quick Look shows nothing for a directory, so space on a folder used
        // to do nothing. Show what is inside it instead.
        if let item = selectedItems.first, selectedItems.count == 1, item.opensAsFolder {
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().orderOut(nil)
            }
            FolderPeekController.shared.toggle(item.url, over: view.window)
            return
        }
        if FolderPeekController.shared.isOpen { FolderPeekController.shared.close() }

        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The editor that renames in place, shared by every view.
    let renameEditor = InlineRenameEditor()

    func beginRename() {
        guard let target = selectedURLs().first else {
            Log.debug(.ui, "rename: nothing selected")
            return
        }
        switch mode {
        case .list:
            beginRenameInList(target)
        case .icon:
            beginRenameInIcons(target)
        case .column:
            // The columns are the delegate's, so it puts the editor up.
            if delegate?.fileList(self, renameInColumns: target) != true { renameThroughSheet() }
        }
    }

    /// Over the name cell, at the name column wherever it has been dragged to.
    private func beginRenameInList(_ target: URL) {
        let row = tableView.selectedRow
        guard row >= 0, items.indices.contains(row) else {
            Log.debug(.ui, "rename: no row, selectedRow \(tableView.selectedRow) of \(items.count)")
            return
        }
        let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard index >= 0 else {
            Log.debug(.ui, "rename: no name column")
            return
        }
        // The cell's own frame, not the column's: the name starts after the
        // icon, and an editor over the icon would look wrong and cover it.
        var rect = tableView.frameOfCell(atColumn: index, row: row)
        if let cell = tableView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView,
           let label = cell.textField {
            rect = label.convert(label.bounds, to: tableView)
            rect = rect.insetBy(dx: -2, dy: -1)
        }
        present(target, in: tableView, rect: rect, alignment: .left)
    }

    /// Over the tile's label, which is centred under the thumbnail.
    private func beginRenameInIcons(_ target: URL) {
        guard let path = collectionView.selectionIndexPaths.first,
              let item = collectionView.item(at: path) else {
            Log.debug(.ui, "rename: no tile for the selection")
            return
        }
        let tile = item.view
        var rect = tile.convert(tile.bounds, to: collectionView)
        // The label sits under the thumbnail, which takes 62% of the width.
        let labelTop = rect.height * 0.62 + 11
        rect = NSRect(x: rect.minX + 2, y: rect.minY + labelTop,
                      width: rect.width - 4, height: 20)
        present(target, in: collectionView, rect: rect, alignment: .center)
    }

    private func present(_ target: URL, in host: NSView, rect: NSRect, alignment: NSTextAlignment) {
        renameEditor.begin(
            name: target.lastPathComponent, in: host, rect: rect, alignment: alignment
        ) { [weak self] newName in
            self?.applyRename(of: target, to: newName)
        }
    }

    /// Renames the file the editor was opened on, whatever has happened to the
    /// rows underneath in the meantime.
    func applyRename(of original: URL, to newName: String) {
        guard newName != original.lastPathComponent else { return }
        guard FileManager.default.fileExists(atPath: original.path) else {
            reload()
            return
        }
        if let error = validateFileName(newName) {
            showError(error)
            return
        }
        do {
            let newURL = try OperationEngine.shared.rename(original, to: newName)
            UndoStack.shared.pushRename(from: original, to: newURL)
            setColumnSelection([newURL])
            reload(selecting: newURL)
            delegate?.fileList(self, didChangeSelection: [newURL])
        } catch {
            showError(error)
        }
    }

    /// Renames the selected file from a sheet, for the views that have no cell
    /// editor. Applies the same validation and undo as the inline editor.
    private func renameThroughSheet() {
        guard let original = selectedURLs().first, let window = view.window else { return }

        let field = NSTextField(string: original.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let base = original.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Rename “\(original.lastPathComponent)”"
        alert.informativeText = "Enter a new name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = field.stringValue
            guard newName != original.lastPathComponent else { return }
            if let error = validateFileName(newName) {
                self.showError(error)
                return
            }
            do {
                let newURL = try OperationEngine.shared.rename(original, to: newName)
                UndoStack.shared.pushRename(from: original, to: newURL)
                self.setColumnSelection([newURL])
                self.reload(selecting: newURL)
                self.delegate?.fileList(self, didChangeSelection: [newURL])
            } catch {
                self.showError(error)
            }
        }

        // The field editor only exists once the sheet is on screen, which is
        // after beginSheetModal returns. Selecting the name without its
        // extension is what stops an accidental extension change.
        if base.count < original.lastPathComponent.count, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: base.count)
        }
    }

    /// Escape leaves the filter field and clears the filter; Return hands focus
    /// back to the list with the filter still applied.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === filterField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endFilter()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            focusTable()
            selectFirstRow()
            return true
        case #selector(NSResponder.moveDown(_:)):
            focusTable()
            selectFirstRow()
            return true
        default:
            return false
        }
    }

    // MARK: - Open With

    /// The Open With list on its own, for the toolbar button to pop up. Same
    /// menu the context menu nests, so the two cannot drift apart.
    func openWithMenu() -> NSMenu? { openWithMenuItem()?.submenu }

    /// The Open With submenu, or nil when the selection has no single type to
    /// offer applications for.
    private func openWithMenuItem() -> NSMenuItem? {
        let urls = selectedURLs()
        guard let first = urls.first else { return nil }
        let candidates = OpenWith.candidates(for: first)
        guard !candidates.isEmpty else { return nil }
        let current = OpenWith.defaultApplication(for: first)

        let submenu = NSMenu()
        for app in candidates {
            let isDefault = app.standardizedFileURL == current?.standardizedFileURL
            let title = isDefault
                ? "\(OpenWith.displayName(of: app)) (default)"
                : OpenWith.displayName(of: app)
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.representedObject = app
            item.image = smallIcon(for: app)
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOtherApp(_:)), keyEquivalent: "")
        other.target = self
        submenu.addItem(other)

        // Changing the default is a system-wide change, so it is a separate,
        // clearly labelled item rather than a modifier on the list above.
        submenu.addItem(.separator())
        let always = NSMenu()
        for app in candidates {
            let item = NSMenuItem(title: OpenWith.displayName(of: app),
                                  action: #selector(setDefaultApp(_:)), keyEquivalent: "")
            item.representedObject = app
            item.image = smallIcon(for: app)
            item.state = app.standardizedFileURL == current?.standardizedFileURL ? .on : .off
            item.target = self
            always.addItem(item)
        }
        let alwaysItem = NSMenuItem(
            title: "Always Open \(OpenWith.typeDescription(of: first)) With", action: nil, keyEquivalent: ""
        )
        alwaysItem.submenu = always
        submenu.addItem(alwaysItem)

        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func smallIcon(for app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        OpenWith.open(urls, with: app, confirmingIn: view.window)
    }

    @objc private func openWithOtherApp(_ sender: Any?) {
        guard !selectedURLs().isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        OpenWith.open(selectedURLs(), with: app, confirmingIn: view.window)
    }

    @objc private func setDefaultApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let file = selectedURLs().first else { return }
        let description = OpenWith.typeDescription(of: file)
        OpenWith.setDefault(app, forTypeOf: file) { [weak self] error in
            guard let self else { return }
            if let error {
                self.delegate?.fileList(self, didReportStatus: "Could not set default: \(error.localizedDescription)")
            } else {
                self.delegate?.fileList(
                    self, didReportStatus: "\(OpenWith.displayName(of: app)) now opens \(description)"
                )
            }
        }
    }

    @objc func duplicateSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        do {
            let created = try OperationEngine.shared.duplicate(urls)
            UndoStack.shared.pushCreated(created, label: "Duplicate")
            reload(selecting: created.first)
        } catch {
            showError(error)
        }
    }

    @objc func trashSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }

        // On a share there is no Trash, so ⌘⌫ deletes outright. Say so before
        // it happens rather than after.
        if let warning = TrashPolicy.warning(for: urls) {
            let alert = NSAlert()
            alert.messageText = warning.title
            alert.informativeText = warning.body
            if case .readOnly = TrashPolicy.outcome(for: urls[0]) {
                alert.runModal()
                return
            }
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Where the cursor should land once the rows are gone. Selecting has to
        // wait for the reload; doing it immediately after landed on the old
        // contents and left nothing selected, so a second ⌘⌫ went up a folder.
        let nextRow = max(0, (tableView.selectedRowIndexes.min() ?? 0))
        OperationEngine.shared.trash(urls) { [weak self] result in
            guard let self else { return }
            UndoStack.shared.pushTrash(result.trashedPairs)
            self.reportFailures(result, verb: "move to Trash")
            self.reload {
                guard !self.items.isEmpty else { return }
                let target = min(nextRow, self.items.count - 1)
                self.tableView.selectRowIndexes([target], byExtendingSelection: false)
                self.tableView.scrollRowToVisible(target)
            }
        }
    }

    @objc func deleteSelectionPermanently() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Delete “\(urls[0].lastPathComponent)” permanently?"
            : "Delete \(urls.count) items permanently?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        OperationEngine.shared.deletePermanently(urls) { [weak self] result in
            self?.reportFailures(result, verb: "delete")
            self?.reload()
        }
    }

    @objc func newFolder() {
        promptForName(title: "New Folder", suggestion: "untitled folder") { [weak self] name in
            guard let self else { return }
            do {
                let created = try OperationEngine.shared.createFolder(named: name, in: self.url)
                UndoStack.shared.pushCreated([created], label: "New Folder")
                self.reload(selecting: created)
            } catch {
                self.showError(error)
            }
        }
    }

    @objc func newFile() {
        promptForName(title: "New File", suggestion: "untitled.txt") { [weak self] name in
            guard let self else { return }
            do {
                let created = try OperationEngine.shared.createFile(named: name, in: self.url)
                UndoStack.shared.pushCreated([created], label: "New File")
                self.reload(selecting: created)
            } catch {
                self.showError(error)
            }
        }
    }

    func copySelection(cut: Bool) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        FileClipboard.write(urls, cut: cut)
        delegate?.fileList(self, didReportStatus: "\(urls.count) item\(urls.count == 1 ? "" : "s") \(cut ? "cut" : "copied")")
    }

    // The Edit menu uses the standard selectors, so a text field's field editor
    // gets first crack at them and ⌘C still copies text while typing. These only
    // run when the file list itself holds focus.

    @objc func copy(_ sender: Any?) { copySelection(cut: false) }
    @objc func cut(_ sender: Any?) { copySelection(cut: true) }
    @objc func paste(_ sender: Any?) { pasteFiles() }

    func pasteFiles() {
        let urls = FileClipboard.read()
        guard !urls.isEmpty else { return }
        let move = FileClipboard.isCut
        receive(urls, move: move)
        if move { FileClipboard.clearCut() }
    }

    /// Shared entry point for paste and drag-and-drop.
    func receive(_ urls: [URL], move: Bool) {
        let destination = url
        OperationEngine.shared.transfer(
            urls,
            to: destination,
            move: move,
            resolveConflict: { [weak self] source, existing in
                self?.askConflict(source: source, existing: existing) ?? ConflictResolution(choice: .skip)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if move {
                    UndoStack.shared.pushMove(result: result)
                } else {
                    UndoStack.shared.pushCopy(result: result)
                }
                self.reportFailures(result, verb: move ? "move" : "copy")
                self.reload(selecting: result.createdDestinations.first)
            }
        )
    }

    /// A drop onto a folder row lands inside that folder rather than the
    /// directory being listed. Every view's drop handler funnels through here.
    func transfer(_ urls: [URL], into destination: URL, move: Bool) {
        OperationEngine.shared.transfer(
            urls,
            to: destination,
            move: move,
            resolveConflict: { [weak self] source, existing in
                self?.askConflict(source: source, existing: existing) ?? ConflictResolution(choice: .skip)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if move {
                    UndoStack.shared.pushMove(result: result)
                } else {
                    UndoStack.shared.pushCopy(result: result)
                }
                self.reportFailures(result, verb: move ? "move" : "copy")
                self.reload()
            }
        )
    }

    @objc func selectAllItems() {
        switch mode {
        case .icon:
            collectionView.selectionIndexPaths = Set(
                (0..<items.count).map { IndexPath(item: $0, section: 0) }
            )
            collectionSelectionChanged()
        case .column:
            delegate?.fileListDidRequestSelectAllInColumns(self)
        case .list:
            tableView.selectAll(nil)
        }
    }

    @objc func invertSelection() {
        // Inverting only the table left the command dead in icon and column view.
        switch mode {
        case .icon:
            let current = collectionView.selectionIndexPaths
            let all = Set((0..<items.count).map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = all.subtracting(current)
            collectionSelectionChanged()
        case .column:
            delegate?.fileListDidRequestInvertSelectionInColumns(self)
        case .list:
            let current = tableView.selectedRowIndexes
            var inverted = IndexSet(integersIn: 0..<items.count)
            inverted.subtract(current)
            tableView.selectRowIndexes(inverted, byExtendingSelection: false)
        }
    }

    /// Click a column to sort by it; shift-click to keep the current sort and
    /// break its ties with the new key.
    func setSort(key: SortKey, additive: Bool = false) {
        if additive { sortOrder.addSecondary(key) } else { sortOrder.makePrimary(key) }
        commitSortChange()
    }

    func reverseSort() {
        sortOrder.reverse()
        commitSortChange()
    }

    func clearSecondarySorts() {
        sortOrder.clearSecondary()
        commitSortChange()
    }

    private func commitSortChange() {
        Prefs.sortOrder = sortOrder
        FolderViewSettings.record(url, viewMode: mode, sortOrder: sortOrder)
        updateSortIndicators()
        applyFilterAndSort(preservingSelection: true)
        delegate?.fileList(self, didReportStatus: "Sorted by " + sortOrder.summary)
    }

    /// Shows the background image, and makes the listing transparent enough for
    /// it to read through. With no image the views go back to opaque, which is
    /// what keeps scrolling fast in the ordinary case.
    func applyBackground() {
        guard isViewLoaded else { return }
        let config = Theme.background
        backgroundView.apply(config, cache: .shared)

        let showing = !backgroundView.isHidden
        scrollView.drawsBackground = !showing
        collectionScroll.drawsBackground = !showing
        tableView.backgroundColor = showing ? .clear : .controlBackgroundColor
        collectionView.backgroundColors = showing ? [.clear] : [.controlBackgroundColor]
        view.needsDisplay = true
    }

    /// Widens each column to fit its longest value.
    ///
    /// Finder's equivalent is a double-click on the divider and it does not
    /// stick; an entire commercial app launched on making this the default.
    /// Measures every row, not only the visible ones, because the point is the
    /// name that is currently cut off further down.
    func fitColumnsToContent() {
        guard isViewLoaded, !items.isEmpty else { return }

        for column in tableView.tableColumns where !column.isHidden {
            let key = column.identifier.rawValue
            // Metadata arrives asynchronously, so fitting it now would measure
            // empty strings and snap the column shut.
            guard key != "git", !key.hasPrefix("meta.") else { continue }
            var widest: CGFloat = column.headerCell.cellSize.width + 12

            for item in items {
                let text = displayText(for: item, column: key)
                guard !text.isEmpty else { continue }
                let font = key == "name" ? Theme.rowName : Theme.rowNumeric
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                // The name column also carries a 16pt icon and its gap.
                widest = max(widest, width + (key == "name" ? 26 : 10))
            }
            // A name column that grows to fit the longest name is a name column
            // that pushes Size and Date off the right-hand edge in any folder
            // holding one long filename. Truncating is the lesser loss.
            let ceiling: CGFloat = key == "name" ? 320 : 600
            column.width = min(max(widest, column.minWidth), ceiling)
        }
    }

    /// The string a column shows for an item, shared by drawing and measuring so
    /// the two cannot drift apart.
    private func displayText(for item: FileItem, column: String) -> String {
        switch column {
        case "name": return item.name
        case "ext": return item.url.pathExtension
        case "kind": return item.kind
        case "modified": return item.modified == .distantPast ? "—" : Self.dateFormatter.string(from: item.modified)
        case "created": return item.created == .distantPast ? "—" : Self.dateFormatter.string(from: item.created)
        case "size":
            if item.isDirectory {
                guard let measured = FolderSizeCalculator.shared.cached(for: item.url) else { return "—" }
                return Self.byteFormatter.string(fromByteCount: measured.bytes)
            }
            return Self.byteFormatter.string(fromByteCount: item.size)
        default: return ""
        }
    }

    /// Reloads the sort from preferences, for when another pane changed it.
    func adoptGlobalViewSettings() {
        sortOrder = FolderViewSettings.sortOrder(for: url)
        updateSortIndicators()
        applyColumnVisibility()
        rebuildMetadataColumns()
        applyViewMode()
        applyBackground()
        applyFilterAndSort(preservingSelection: true)
    }

    private func updateSortIndicators() {
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
            guard let key = SortKey(rawValue: column.identifier.rawValue),
                  let ascending = sortOrder.direction(for: key) else { continue }
            let name: NSImage.Name = ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            tableView.setIndicatorImage(NSImage(named: name), in: column)
            if sortOrder.primary?.key == key { tableView.highlightedTableColumn = column }
            // Secondary keys are numbered in the header so a multi-key sort is
            // readable without opening a menu.
            if let position = sortOrder.position(of: key), position > 0 {
                column.headerToolTip = "Sort key \(position + 1): \(key.title)"
            } else {
                column.headerToolTip = key.title
            }
        }
    }

    /// Adds or removes the optional metadata columns to match the setting.
    func rebuildMetadataColumns() {
        guard isViewLoaded else { return }
        let wanted = MetadataColumns.enabled

        for column in tableView.tableColumns where column.identifier.rawValue.hasPrefix("meta.") {
            tableView.removeTableColumn(column)
        }
        for field in wanted {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meta.\(field.rawValue)"))
            column.title = field.title
            column.width = field.columnWidth
            column.minWidth = 60
            tableView.addTableColumn(column)
        }

        MetadataReader.shared.onUpdate = { [weak self] url in
            guard let self, self.isViewLoaded, !MetadataColumns.enabled.isEmpty else { return }
            guard let row = self.items.firstIndex(where: { $0.url == url }) else { return }
            self.tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<self.tableView.numberOfColumns))
        }
        if !wanted.isEmpty { requestMetadata() }
        tableView.reloadData()
    }

    /// Reads metadata for what is on screen. Files are read one at a time in the
    /// background; nothing here blocks the listing.
    private func requestMetadata() {
        guard !MetadataColumns.enabled.isEmpty else { return }
        for item in items where !item.isDirectory {
            MetadataReader.shared.read(item.url)
        }
    }

    private func applyColumnVisibility() {
        for column in tableView.tableColumns where column.identifier.rawValue == "git" {
            column.isHidden = !Prefs.showGitStatus
        }
    }

    // MARK: - Dialogs

    private func askConflict(source: URL, existing: URL) -> ConflictResolution {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        var existingIsDirectory: ObjCBool = false
        let sourceExists = fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
        _ = fm.fileExists(atPath: existing.path, isDirectory: &existingIsDirectory)
        let bothFolders = sourceIsDirectory.boolValue && existingIsDirectory.boolValue

        let alert = NSAlert()
        alert.messageText = "“\(existing.lastPathComponent)” already exists here"

        let describe: (URL) -> String = { u in
            let values = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let date = values?.contentModificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
            if values?.isDirectory == true {
                let count = (try? fm.contentsOfDirectory(atPath: u.path).count) ?? 0
                return "folder, \(count) item\(count == 1 ? "" : "s"), modified \(date)"
            }
            let size = values?.fileSize.map { Self.byteFormatter.string(fromByteCount: Int64($0)) } ?? "—"
            return "\(size), modified \(date)"
        }

        var info = "Existing: \(describe(existing))\n\(existing.deletingLastPathComponent().path)"
        if sourceExists {
            info += "\n\nIncoming: \(describe(source))\n\(source.deletingLastPathComponent().path)"
        }
        // The warning belongs to the destination being a folder, not to both
        // sides being folders. A file landing on a folder is the same loss —
        // the whole tree goes — and Merge is not even offered to soften it.
        if bothFolders {
            info += "\n\nMerge keeps everything already in the folder and adds what is new."
                + "\nReplace deletes the existing folder and everything inside it."
        } else if existingIsDirectory.boolValue {
            let count = (try? fm.contentsOfDirectory(atPath: existing.path).count) ?? 0
            info += "\n\nReplace deletes the existing folder and the \(count) item"
                + "\(count == 1 ? "" : "s") inside it, and puts a file in its place."
        }
        alert.informativeText = info

        // Merge is first for folders because replacing a folder is destructive
        // and merging almost always the intent.
        if bothFolders { alert.addButton(withTitle: "Merge") }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        let applyToAll = NSButton(checkboxWithTitle: "Apply to all remaining conflicts", target: nil, action: nil)
        let skipIdentical = NSButton(checkboxWithTitle: "Skip files that are identical", target: nil, action: nil)
        let accessory = NSStackView(views: [applyToAll, skipIdentical])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 4
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        alert.accessoryView = accessory

        let response = alert.runModal()
        let order: [ConflictChoice] = bothFolders
            ? [.merge, .keepBoth, .replace, .skip, .cancel]
            : [.keepBoth, .replace, .skip, .cancel]
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = order.indices.contains(index) ? order[index] : .cancel

        return ConflictResolution(
            choice: choice,
            applyToAll: applyToAll.state == .on,
            skipIdentical: skipIdentical.state == .on
        )
    }

    private func promptForName(title: String, suggestion: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let error = validateFileName(name) { showError(error); return }
            completion(name)
        }
    }

    private func reportFailures(_ result: OperationResult, verb: String) {
        guard !result.failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not \(verb) \(result.failures.count) item\(result.failures.count == 1 ? "" : "s")"
        alert.informativeText = result.failures.prefix(8)
            .map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
            .joined(separator: "\n")
        alert.runModal()
    }

    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: - Context menu

    func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        let hasSelection = !selectedURLs().isEmpty

        if hasSelection {
            menu.addItem(withTitle: "Open", action: #selector(openSelection), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTabAction), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open in Opposite Pane", action: #selector(openInOppositePaneAction), keyEquivalent: "").target = self
            if let openWith = openWithMenuItem() { menu.addItem(openWith) }
            menu.addItem(withTitle: Archiver.menuTitle(for: selectedURLs()),
                         action: #selector(compressSelection), keyEquivalent: "").target = self
            menu.addItem(tagsMenuItem())
            menu.addItem(withTitle: "Make Symlink", action: #selector(makeSymlink), keyEquivalent: "").target = self
            if selectedItems.count == 1, PackageContents.canInspect(selectedItems[0]) {
                menu.addItem(withTitle: "Show Package Contents",
                             action: #selector(showPackageContents), keyEquivalent: "").target = self
            }
            if selectedItems.count == 1, selectedItems[0].url.pathExtension == "app" {
                menu.addItem(withTitle: "Uninstall…",
                             action: #selector(uninstallApp), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
        }

        if hasSelection {
            // The research is emphatic that these belong in the plain menu, not
            // behind a modifier or a submenu.
            menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        }
        if !FileClipboard.read().isEmpty {
            let title = FileClipboard.isCut ? "Move Items Here" : "Paste Items Here"
            menu.addItem(withTitle: title, action: #selector(paste(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())

        // Copy Path directly, with the other formats one level down.
        let copyPathDirect = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromMenu(_:)), keyEquivalent: "")
        copyPathDirect.representedObject = PathFormat.absolute.title
        copyPathDirect.target = self
        menu.addItem(copyPathDirect)

        let copyMenu = NSMenu()
        for format in PathFormat.allCases {
            let item = NSMenuItem(title: format.title, action: #selector(copyPathFromMenu(_:)), keyEquivalent: "")
            item.representedObject = format.title
            item.target = self
            copyMenu.addItem(item)
        }
        let copyItem = NSMenuItem(title: "Copy Path As", action: nil, keyEquivalent: "")
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "").target = self
        let terminalItem = NSMenuItem(title: "Open in Terminal", action: nil, keyEquivalent: "")
        terminalItem.submenu = MainWindowController.terminalPickerPlaceholder()
        menu.addItem(terminalItem)
        menu.addItem(.separator())

        if hasSelection {
            menu.addItem(withTitle: "Rename…", action: #selector(renameFromMenu), keyEquivalent: "").target = self
            if selectedURLs().count > 1 {
                menu.addItem(withTitle: "Rename \(selectedURLs().count) Items…",
                             action: #selector(MainWindowController.menuBatchRename(_:)), keyEquivalent: "")
            }
            if let first = selectedURLs().first, Archive.isArchive(first) {
                menu.addItem(withTitle: "Look Inside Archive…",
                             action: #selector(MainWindowController.menuOpenArchive(_:)), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Move to Trash", action: #selector(trashSelection), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "").target = self

        let newFileItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        newFileItem.submenu = newFileTemplateMenu()
        menu.addItem(newFileItem)
        return menu
    }

    /// One entry per template, so a file can be made where you are standing
    /// rather than made elsewhere and moved.
    private func newFileTemplateMenu() -> NSMenu {
        let menu = NSMenu()
        for template in FileTemplate.all {
            let item = NSMenuItem(title: template.title, action: #selector(newFileFromTemplate(_:)), keyEquivalent: "")
            item.representedObject = template.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Empty File…", action: #selector(newFile), keyEquivalent: "").target = self
        return menu
    }

    @objc private func newFileFromTemplate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let template = FileTemplate.all.first(where: { $0.id == id })
        else { return }
        do {
            let created = try OperationEngine.shared.createFile(
                named: OperationEngine.uniqueURL(
                    for: url.appendingPathComponent(template.defaultName),
                    fileManager: .default
                ).lastPathComponent,
                in: url,
                contents: template.contents
            )
            UndoStack.shared.pushCreated([created], label: "New \(template.title)")
            reload(selecting: created) { [weak self] in self?.beginRename() }
        } catch {
            showError(error)
        }
    }

    @objc private func renameFromMenu() { beginRename() }

    @objc private func copyPathFromMenu(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let format = PathFormat.allCases.first(where: { $0.title == title }) else { return }
        copyToPasteboard(targetURLs(), format: format)
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

// MARK: - Table data source and delegate

extension FileListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, items.indices.contains(row) else { return nil }
        let item = items[row]
        let id = tableColumn.identifier

        let cell: FileCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? FileCellView {
            cell = reused
        } else {
            cell = makeCell(identifier: id, showsIcon: id.rawValue == "name")
        }
        // Rows are reused, so the inverted state has to be reapplied per row.
        cell.isOnFilledSelection = (tableView.rowView(atRow: row, makeIfNecessary: false) as? FileRowView)?
            .wantsInvertedText ?? tableView.selectedRowIndexes.contains(row)

        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            cell.textField?.font = Theme.rowName
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.restingTextColor = item.isHidden ? .secondaryLabelColor : .labelColor
        case "size":
            if item.isDirectory {
                if let measured = FolderSizeCalculator.shared.cached(for: item.url) {
                    cell.textField?.stringValue = Self.byteFormatter.string(fromByteCount: measured.bytes)
                    cell.toolTip = "\(measured.fileCount) file\(measured.fileCount == 1 ? "" : "s")"
                } else {
                    cell.textField?.stringValue = Prefs.calculateFolderSizes ? "…" : "—"
                    cell.toolTip = nil
                }
            } else {
                cell.textField?.stringValue = Self.byteFormatter.string(fromByteCount: item.size)
            }
            cell.textField?.font = Theme.rowNumeric
            cell.restingTextColor = .secondaryLabelColor
            cell.textField?.alignment = .right
        case "ext":
            cell.textField?.stringValue = item.url.pathExtension
            cell.textField?.font = Theme.rowNumeric
            cell.restingTextColor = .secondaryLabelColor
        case "git":
            let state = gitStatuses[item.url.standardizedFileURL.path] ?? .clean
            cell.textField?.stringValue = state.badge
            cell.textField?.font = Theme.rowNumeric
            cell.textField?.alignment = .center
            cell.restingTextColor = state == .clean ? .tertiaryLabelColor : Theme.accent
            cell.toolTip = state == .clean ? nil : state.label
        case "created":
            cell.textField?.stringValue = item.created == .distantPast ? "—" : Self.dateFormatter.string(from: item.created)
            cell.textField?.font = Theme.rowNumeric
            cell.restingTextColor = .secondaryLabelColor
        case "kind":
            cell.textField?.stringValue = item.kind
            cell.textField?.font = Theme.rowSecondary
            cell.restingTextColor = .secondaryLabelColor
        case "modified":
            cell.textField?.stringValue = item.modified == .distantPast ? "—" : Self.dateFormatter.string(from: item.modified)
            cell.textField?.font = Theme.rowNumeric
            cell.restingTextColor = .secondaryLabelColor
        default:
            if id.rawValue.hasPrefix("meta."),
               let field = MetadataField(rawValue: String(id.rawValue.dropFirst(5))) {
                cell.textField?.stringValue = MetadataReader.shared.value(field, for: item.url) ?? ""
                cell.textField?.font = Theme.rowNumeric
                cell.restingTextColor = .secondaryLabelColor
            } else {
                cell.textField?.stringValue = ""
            }
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) -> FileCellView {
        let cell = FileCellView()
        cell.identifier = identifier

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.font = Theme.rowName
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.cell?.usesSingleLineMode = true
        cell.addSubview(field)
        cell.textField = field

        if showsIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0).isActive = true
        }

        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("filerow")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? FileRowView) ?? {
            let fresh = FileRowView()
            fresh.identifier = id
            return fresh
        }()
        view.isAlternateRow = row % 2 == 1
        view.tagTint = items.indices.contains(row) ? Tags.rowTint(for: Tags.read(items[row].url)) : nil
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedURLsCache = selectedURLs()
        reportStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = SortKey(rawValue: tableColumn.identifier.rawValue) else { return }
        let additive = NSEvent.modifierFlags.contains(.shift)
        setSort(key: key, additive: additive)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items.indices.contains(row) ? items[row].name : nil
    }

    // Drag out
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items.indices.contains(row) ? items[row].url as NSURL : nil
    }

    /// Says how to back out, for the length of the drag.
    ///
    /// AppKit cancels a drag when Escape is pressed, but nothing anywhere says
    /// so, and a drag picked up by accident otherwise has to be carried back to
    /// where it started. The line goes in the status bar and is taken away when
    /// the drag ends, however it ends.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        reportDragHint(count: rowIndexes.count)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        reportStatus()
    }

    // Drop in
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let dragged = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !dragged.isEmpty else { return [] }

        // Dropping onto a folder row targets that folder; anywhere else targets
        // the current directory.
        if dropOperation == .on, items.indices.contains(row), items[row].opensAsFolder {
            if dragged.contains(items[row].url) { return [] }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        tableView.setDropRow(-1, dropOperation: .on)
        if dragged.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == url }) { return [] }
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let dragged = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !dragged.isEmpty else { return false }

        let move = info.draggingSourceOperationMask.contains(.move)
        if dropOperation == .on, items.indices.contains(row), items[row].opensAsFolder {
            transfer(dragged, into: items[row].url, move: move)
        } else {
            receive(dragged, move: move)
        }
        return true
    }
}

// MARK: - Quick Look data source

extension FileListViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs()
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys should keep driving the list while the panel is open.
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            tableView.keyDown(with: event)
            return true
        }
        return false
    }
}


// MARK: - Icon view data source

extension FileListViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
        guard let tile = cell as? FileIconItem, items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        tile.configure(with: item, gitState: gitStatuses[item.url.standardizedFileURL.path] ?? .clean)
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        collectionSelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        collectionSelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        reportDragHint(count: indexPaths.count)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        reportStatus()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
    }

    // Drop in — the same rules as the list: a folder tile is a target of its
    // own, anywhere else is the directory being shown.
    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop info: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard let dragged = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !dragged.isEmpty else { return [] }

        let item = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, items.indices.contains(item), items[item].opensAsFolder {
            if dragged.contains(items[item].url) { return [] }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        dropOperation.pointee = .before
        if dragged.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == url }) { return [] }
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop info: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let dragged = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !dragged.isEmpty else { return false }

        let move = info.draggingSourceOperationMask.contains(.move)
        if dropOperation == .on, items.indices.contains(indexPath.item), items[indexPath.item].opensAsFolder {
            transfer(dragged, into: items[indexPath.item].url, move: move)
        } else {
            receive(dragged, move: move)
        }
        return true
    }
}
