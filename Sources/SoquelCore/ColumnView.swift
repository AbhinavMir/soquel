import AppKit

/// Column view: one pane per directory level, side by side, the way Finder's
/// column browser works.
///
/// The research calls this the one Finder view power users actually defend, and
/// separately records people rejecting it as a substitute for a tree — so both
/// exist here rather than one standing in for the other.
/// A column's table. Key handling is forwarded so the same shortcuts work here
/// as in the list view, rather than only where the table happens to live.
final class ColumnTableView: NSTableView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class ColumnBrowserView: NSView {
    /// Called when the user picks something: a folder to descend into, or a
    /// file to act on.
    var onSelect: ((URL, Bool) -> Void)?
    /// Everything selected in the deepest column, for commands that act on a
    /// set rather than on one file.
    var onSelectMany: (([URL]) -> Void)?
    /// Called when a row is opened (double-click or Return).
    var onOpen: ((URL) -> Void)?
    /// Handles a key press before the table sees it; returns true if consumed.
    var onKeyDown: ((NSEvent) -> Bool)?

    private var scroll: NSScrollView!
    /// One entry per visible column: the folder it lists and its contents.
    private var levels: [(url: URL, items: [FileItem], table: NSTableView,
                          container: NSScrollView, divider: ColumnDivider)] = []

    /// Narrows the deepest column. Only the deepest: the columns to its left
    /// are the path you took to get here, and hiding a folder you are standing
    /// inside would leave the view describing a route that is not on screen.
    private var filterText = ""

    /// One width for every column, dragged from any divider and remembered.
    ///
    /// Finder sizes its columns individually; one width for all of them is a
    /// simpler thing to explain and to drag, and the width people actually want
    /// is "wide enough for these names", which is the same answer in every
    /// column of the same folder.
    static var columnWidth: CGFloat {
        get {
            let stored = Settings.object(forKey: "columnViewWidth") as? Double ?? 240
            return CGFloat(Swift.min(Swift.max(stored, minimumColumnWidth), maximumColumnWidth))
        }
        set {
            Settings.set(
                Double(Swift.min(Swift.max(newValue, minimumColumnWidth), maximumColumnWidth)),
                forKey: "columnViewWidth"
            )
        }
    }

    /// Narrow enough to be useful, never narrow enough to hide every name.
    static let minimumColumnWidth: CGFloat = 140
    static let maximumColumnWidth: CGFloat = 640

    /// A column's rows as drawn, which is its contents with the filter applied
    /// when it is the deepest one.
    func items(at index: Int) -> [FileItem] {
        guard levels.indices.contains(index) else { return [] }
        let all = levels[index].items
        guard index == levels.count - 1, !filterText.isEmpty else { return all }
        let needle = filterText.lowercased()
        return all.filter { $0.name.lowercased().contains(needle) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Laid out by hand rather than with constraints.
    ///
    /// Columns are added and removed constantly, and every constraint-based
    /// attempt fed the scroll view's growing content size back into the pane and
    /// pushed the pane's own chrome off screen. Frames are computed here from a
    /// fixed column width, which cannot feed back into anything.
    private var documentView: NSView!

    private func build() {
        documentView = NSView()

        scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
    }

    override func layout() {
        super.layout()
        layoutColumns()
    }

    /// Places every column side by side at the full height of the view.
    private func layoutColumns() {
        let height = scroll.contentSize.height
        var x: CGFloat = 0
        for level in levels {
            level.container.frame = NSRect(x: x, y: 0, width: Self.columnWidth, height: height)
            x += Self.columnWidth
            level.divider.frame = NSRect(x: x - 3, y: 0, width: 7, height: height)
            x += 1
        }
        documentView.frame = NSRect(x: 0, y: 0, width: max(x, scroll.contentSize.width), height: height)
    }

    /// Shows `url` as the leftmost column, discarding anything to the right.
    func show(_ url: URL) {
        clearLevels()
        appendColumn(for: url)
    }

    /// The folder the rightmost column is listing.
    var deepestURL: URL? { levels.last?.url }

    private func clearLevels() {
        for level in levels {
            level.container.removeFromSuperview()
            level.divider.removeFromSuperview()
        }
        levels.removeAll()
    }

    /// Drops every column to the right of `index`, which is what happens when
    /// the selection in an earlier column changes.
    private func truncate(after index: Int) {
        while levels.count > index + 1 {
            let level = levels.removeLast()
            level.container.removeFromSuperview()
            level.divider.removeFromSuperview()
        }
        layoutColumns()
    }

    private func appendColumn(for url: URL) {
        let table = ColumnTableView()
        table.onKeyDown = { [weak self] event in self?.onKeyDown?(event) ?? false }
        table.headerView = nil
        table.rowHeight = Theme.rowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.allowsMultipleSelection = true
        table.doubleAction = #selector(openClicked)
        table.identifier = NSUserInterfaceItemIdentifier(url.path)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = Self.columnWidth - 4
        table.addTableColumn(column)

        let columnScroll = NSScrollView()
        columnScroll.documentView = table
        columnScroll.hasVerticalScroller = true
        columnScroll.drawsBackground = false

        let divider = ColumnDivider()
        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            Self.columnWidth = Self.columnWidth + delta
            self.needsLayout = true
            self.layoutColumns()
        }

        documentView.addSubview(columnScroll)
        documentView.addSubview(divider)
        levels.append((url, [], table, columnScroll, divider))
        layoutColumns()

        // Listings load off the main thread, as everywhere else.
        let index = levels.count - 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = (try? DirectoryLoader.read(url, showHidden: Prefs.showHiddenFiles)) ?? []
            let sorted = sortItems(items, order: Prefs.sortOrder, foldersFirst: Prefs.foldersFirst)
            DispatchQueue.main.async {
                guard let self, self.levels.indices.contains(index),
                      self.levels[index].url == url else { return }
                self.levels[index].items = sorted
                self.levels[index].table.reloadData()
            }
        }
    }

    private func levelIndex(for table: NSTableView) -> Int? {
        levels.firstIndex { $0.table === table }
    }

    @objc private func openClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView ?? (sender as? NSObject as? NSTableView),
              let index = levelIndex(for: table),
              items(at: index).indices.contains(table.selectedRow)
        else { return }
        onOpen?(items(at: index)[table.selectedRow].url)
    }

    /// Scrolls so the newest column is visible, which is the point of the view.
    private func scrollToEnd() {
        guard let last = levels.last else { return }
        scroll.contentView.scrollToVisible(last.container.frame)
    }
}

extension ColumnBrowserView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let index = levelIndex(for: tableView) else { return 0 }
        return items(at: index).count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = levelIndex(for: tableView), items(at: index).indices.contains(row)
        else { return nil }
        let item = items(at: index)[row]

        let cell = FileCellView()
        let field = NSTextField(labelWithString: item.name)
        field.font = Theme.rowName
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(field)
        cell.textField = field
        cell.imageView = icon
        cell.restingTextColor = item.isHidden ? .secondaryLabelColor : .labelColor

        // A folder gets a chevron, so it is obvious which rows go deeper.
        var trailing: NSView = cell
        if item.opensAsFolder {
            let chevron = NSImageView()
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Folder")
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 9),
            ])
            trailing = chevron
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(
                equalTo: trailing === cell ? cell.trailingAnchor : trailing.leadingAnchor,
                constant: -6
            ),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              let index = levelIndex(for: table),
              items(at: index).indices.contains(table.selectedRow)
        else { return }

        let rows = items(at: index)
        let chosen = table.selectedRowIndexes.compactMap { row in
            rows.indices.contains(row) ? rows[row] : nil
        }
        let item = rows[table.selectedRow]
        truncate(after: index)

        // Only a single folder opens the next column. A range or a scattered
        // set has no one folder to descend into, and descending into the last
        // one clicked would throw away the selection being built.
        if chosen.count == 1, item.opensAsFolder {
            appendColumn(for: item.url.resolvingSymlinksInPath())
            DispatchQueue.main.async { [weak self] in self?.scrollToEnd() }
        }
        onSelect?(item.url, chosen.count == 1 && item.opensAsFolder)
        onSelectMany?(chosen.map(\.url))
    }
}


extension ColumnBrowserView {
    /// Narrows the deepest column as you type in the filter box.
    ///
    /// The file list filters its own table, which is not what is on screen
    /// here, so the box appeared to do nothing in this view.
    func applyFilter(_ text: String) {
        filterText = text
        levels.last?.table.reloadData()
    }

    /// Selects the first row in the deepest column whose name starts with
    /// `prefix`. The file list's own type-select drives a table that is not on
    /// screen in this view, so typing appeared to do nothing.
    @discardableResult
    func typeSelect(prefix: String) -> Bool {
        guard let level = levels.last else { return false }
        let rows = items(at: levels.count - 1)
        guard let match = rows.firstIndex(where: {
            $0.name.lowercased().hasPrefix(prefix.lowercased())
        }) else { return false }
        level.table.selectRowIndexes([match], byExtendingSelection: false)
        level.table.scrollRowToVisible(match)
        return true
    }

    /// Everything selected in the deepest column.
    var selectedURLs: [URL] {
        guard let level = levels.last else { return [] }
        let rows = items(at: levels.count - 1)
        return level.table.selectedRowIndexes.compactMap {
            rows.indices.contains($0) ? rows[$0].url : nil
        }
    }

    /// Selects every row of the deepest column, for ⌘A.
    func selectAllInDeepestColumn() {
        guard let level = levels.last else { return }
        level.table.selectAll(nil)
    }

    /// The rect of a file's name in whichever column is showing it, in that
    /// column's own table. Nil when the file is not on screen.
    func nameRect(for url: URL) -> (host: NSView, rect: NSRect)? {
        for index in levels.indices.reversed() {
            let rows = items(at: index)
            guard let row = rows.firstIndex(where: { $0.url == url }) else { continue }
            let table = levels[index].table
            var rect = table.frameOfCell(atColumn: 0, row: row)
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
               let label = cell.textField {
                rect = label.convert(label.bounds, to: table).insetBy(dx: -2, dy: -1)
            }
            return (table, rect)
        }
        return nil
    }

    /// Re-reads the deepest column, for after a trash or a rename.
    func refreshDeepest() {
        guard let url = levels.last?.url else { return }
        show(url)
    }
}


/// The line between two columns, which is also the handle that resizes them.
///
/// A one-pixel separator is not something anyone can grab, so the view is seven
/// points wide and draws its line down the middle.
final class ColumnDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastX else { return }
        let now = convert(event.locationInWindow, from: nil).x
        // The delta is reported against this view, which the drag itself moves,
        // so the anchor is not updated: doing that would halve every movement.
        onDrag?(now - previous)
    }

    override func mouseUp(with event: NSEvent) {
        lastX = nil
    }
}
