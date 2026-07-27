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
    /// Called when a row is opened (double-click or Return).
    var onOpen: ((URL) -> Void)?
    /// Handles a key press before the table sees it; returns true if consumed.
    var onKeyDown: ((NSEvent) -> Bool)?

    private var scroll: NSScrollView!
    /// One entry per visible column: the folder it lists and its contents.
    private var levels: [(url: URL, items: [FileItem], table: NSTableView,
                          container: NSScrollView, divider: NSView)] = []

    static let columnWidth: CGFloat = 240

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
            level.divider.frame = NSRect(x: x, y: 0, width: 1, height: height)
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
        table.doubleAction = #selector(openClicked)
        table.identifier = NSUserInterfaceItemIdentifier(url.path)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = Self.columnWidth - 4
        table.addTableColumn(column)

        let columnScroll = NSScrollView()
        columnScroll.documentView = table
        columnScroll.hasVerticalScroller = true
        columnScroll.drawsBackground = false

        let divider = NSBox()
        divider.boxType = .separator

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
              levels[index].items.indices.contains(table.selectedRow)
        else { return }
        onOpen?(levels[index].items[table.selectedRow].url)
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
        return levels[index].items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = levelIndex(for: tableView), levels[index].items.indices.contains(row)
        else { return nil }
        let item = levels[index].items[row]

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
              levels[index].items.indices.contains(table.selectedRow)
        else { return }

        let item = levels[index].items[table.selectedRow]
        truncate(after: index)

        if item.opensAsFolder {
            appendColumn(for: item.url.resolvingSymlinksInPath())
            DispatchQueue.main.async { [weak self] in self?.scrollToEnd() }
        }
        onSelect?(item.url, item.opensAsFolder)
    }
}
