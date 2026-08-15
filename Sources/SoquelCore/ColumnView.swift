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
    /// Called when files are dropped on a column: the files, the folder they
    /// land in, and whether they move rather than copy. The pane owns the
    /// transfer machinery, so the drop is handed up rather than done here.
    var onDropFiles: (([URL], URL, Bool) -> Void)?
    /// Called when descending or backing out clears the filter, so the pane
    /// can empty its filter box rather than showing a filter that is off.
    var onFilterCleared: (() -> Void)?

    /// Suppresses selection reporting while a reload re-selects the same
    /// files by URL; without it the re-selection re-enters the descend logic
    /// and appends a duplicate column.
    private var isRemappingSelection = false

    private var scroll: NSScrollView!
    /// One entry per visible column: the folder it lists and its contents.
    /// `message` overlays the column when its listing failed, because an
    /// unreadable folder drawn as an empty one tells the user the wrong thing.
    private var levels: [(url: URL, items: [FileItem], table: NSTableView,
                          container: NSScrollView, divider: ColumnDivider,
                          message: NSTextField)] = []

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
            fitTable(level.table, in: level.container)
            if !level.message.isHidden {
                let inset: CGFloat = 12
                let width = Self.columnWidth - inset * 2
                let size = level.message.sizeThatFits(NSSize(width: width, height: height))
                level.message.frame = NSRect(
                    x: x + inset,
                    y: max((height - size.height) / 2, 0),
                    width: width,
                    height: min(size.height, height)
                )
            }
            x += Self.columnWidth
            level.divider.frame = NSRect(x: x - 3, y: 0, width: 7, height: height)
            x += 1
        }
        documentView.frame = NSRect(x: 0, y: 0, width: max(x, scroll.contentSize.width), height: height)
    }

    /// Sizes a column's one table column to the clip view it scrolls in.
    ///
    /// Left to its own autoresizing, the table came out of the first layout
    /// wider than its clip view, and the chevrons that hang off the trailing
    /// edge sat under the vertical scroller until a divider drag changed the
    /// clip's size and the table with it. That autoresizing only reacts to a
    /// change in the clip's size, so every later layout that set the same
    /// frame again left the table as it was. The width is set outright here,
    /// from the clip view's real size, on the first pass and on every one
    /// after it.
    private func fitTable(_ table: NSTableView, in container: NSScrollView) {
        guard let column = table.tableColumns.first else { return }
        let width = container.contentSize.width - table.intercellSpacing.width
        if column.width != width { column.width = width }
    }

    /// Shows `url` as the leftmost column, discarding anything to the right.
    func show(_ url: URL) {
        clearLevels()
        // Nothing is selected in a browser that was just rebuilt, and the
        // pane's mirror of the selection has to hear that, or Delete acts on
        // files that are no longer on screen.
        onSelectMany?([])
        appendColumn(for: url)
    }

    /// The pane hides the browser when another view takes the pane, and shows
    /// it again on the way back. While it is hidden the pane navigates without
    /// telling it, so the columns drilled into before the hide describe a
    /// visit the pane may since have left; the pane compares only the root on
    /// the way back, and a matching root kept the stale descendants on screen,
    /// scrolled to the far right. Coming back therefore starts at the root
    /// column, the same as a fresh show(), and the pane's mirror hears that
    /// nothing is selected. Watched here rather than in viewDidUnhide so that
    /// only the pane's own switch counts, not a collapsed ancestor.
    override var isHidden: Bool {
        didSet {
            guard oldValue, !isHidden else { return }
            collapseToRoot()
        }
    }

    /// Drops every column but the first and clears what the first had
    /// selected. The filter is kept: the pane keeps its box in step across
    /// the switch, and the root is now the deepest column, so the filter
    /// applies to it the same way it applied to the list.
    private func collapseToRoot() {
        guard let root = levels.first else { return }
        while levels.count > 1 {
            let level = levels.removeLast()
            level.container.removeFromSuperview()
            level.divider.removeFromSuperview()
            level.message.removeFromSuperview()
        }
        // The deselect and the reload both post selection changes; suppressed,
        // or the descend logic would run on a browser that is being torn down.
        isRemappingSelection = true
        root.table.deselectAll(nil)
        root.table.reloadData()
        isRemappingSelection = false
        layoutColumns()
        // The stale columns had scrolled the view to the far right, and a
        // document that shrinks back leaves the clip wherever it was.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        onSelectMany?([])
    }

    /// The folder the rightmost column is listing.
    var deepestURL: URL? { levels.last?.url }

    /// The folder the leftmost column is listing — the root of the drill-down.
    var rootURL: URL? { levels.first?.url }

    private func clearLevels() {
        for level in levels {
            level.container.removeFromSuperview()
            level.divider.removeFromSuperview()
            level.message.removeFromSuperview()
        }
        levels.removeAll()
    }

    /// Drops every column to the right of `index`, which is what happens when
    /// the selection in an earlier column changes.
    private func truncate(after index: Int) {
        guard levels.count > index + 1 else { return }
        clearFilterForDepthChange()
        while levels.count > index + 1 {
            let level = levels.removeLast()
            level.container.removeFromSuperview()
            level.divider.removeFromSuperview()
            level.message.removeFromSuperview()
        }
        layoutColumns()
    }

    /// The filter narrows the deepest column, and only the deepest. When the
    /// depth changes, the filtered rows on screen would stop matching what
    /// items(at:) returns for that column, and a click would act on a
    /// different file than the one clicked — so the filter is cleared, the
    /// column redrawn, and its selection carried over by URL, not by row.
    private func clearFilterForDepthChange() {
        guard !filterText.isEmpty, let level = levels.last else { return }
        let filtered = items(at: levels.count - 1)
        let selected = level.table.selectedRowIndexes.compactMap {
            filtered.indices.contains($0) ? filtered[$0].url : nil
        }
        filterText = ""
        onFilterCleared?()
        level.table.reloadData()
        let full = items(at: levels.count - 1)
        let rows = IndexSet(selected.compactMap { url in full.firstIndex { $0.url == url } })
        isRemappingSelection = true
        level.table.selectRowIndexes(rows, byExtendingSelection: false)
        isRemappingSelection = false
    }

    private func appendColumn(for url: URL) {
        // A descend from the filtered deepest column changes the depth the
        // same way a truncate does. The first column of a fresh show() keeps
        // the filter: a refresh after a rename is not a navigation.
        if !levels.isEmpty { clearFilterForDepthChange() }
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
        // Columns had no drag support at all: files could not be dragged out of
        // this view or dropped into it.
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = Self.columnWidth - 4
        table.addTableColumn(column)

        let columnScroll = NSScrollView()
        columnScroll.documentView = table
        columnScroll.hasVerticalScroller = true
        columnScroll.drawsBackground = false

        let divider = ColumnDivider()
        divider.onDrag = { [weak self, weak divider] delta in
            guard let self, let divider,
                  let index = self.levels.firstIndex(where: { $0.divider === divider })
            else { return }
            // Divider N sits at the right edge of column N, so one point of
            // width change moves it by N + 1 points. The pointer's travel is
            // divided across the columns to its left, and the divider under
            // the pointer tracks it exactly at every depth instead of
            // overshooting and oscillating between the clamps.
            Self.columnWidth = Self.columnWidth + delta / CGFloat(index + 1)
            self.needsLayout = true
            self.layoutColumns()
        }

        let message = NSTextField(wrappingLabelWithString: "")
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)
        message.alignment = .center
        message.isSelectable = false
        message.isHidden = true

        documentView.addSubview(columnScroll)
        documentView.addSubview(divider)
        documentView.addSubview(message)
        levels.append((url, [], table, columnScroll, divider, message))
        layoutColumns()

        loadColumn(at: levels.count - 1)
    }

    /// Reads a level's folder off the main thread and puts the result on
    /// screen, carrying the selection over by URL across the reload. The
    /// failure is shown in the column itself: swallowing it drew a permission
    /// error exactly like a truly empty folder.
    private func loadColumn(at index: Int) {
        guard levels.indices.contains(index) else { return }
        let url = levels[index].url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryLoader.read(url, showHidden: Prefs.showHiddenFiles) }
                .map { sortItems($0, order: Prefs.sortOrder, foldersFirst: Prefs.foldersFirst) }
            DispatchQueue.main.async {
                guard let self, self.levels.indices.contains(index),
                      self.levels[index].url == url else { return }
                let level = self.levels[index]
                let before = self.items(at: index)
                let previous = level.table.selectedRowIndexes.compactMap {
                    before.indices.contains($0) ? before[$0].url : nil
                }
                switch result {
                case .success(let items):
                    self.levels[index].items = items
                    // macOS hands a sandboxed-out app an empty listing rather
                    // than an error for the privacy-gated folders, so an
                    // empty result there is ambiguous and has to say so.
                    if items.isEmpty, FileListViewController.isPrivacyProtected(url) {
                        level.message.stringValue = FileListViewController.emptyMessage(for: url)
                        level.message.isHidden = false
                    } else {
                        level.message.isHidden = true
                    }
                case .failure(let error):
                    self.levels[index].items = []
                    level.message.stringValue = error.localizedDescription
                    level.message.isHidden = false
                }
                // The reload moves the table's selection by row, which can
                // land on different files or fire the descend logic mid-way,
                // so reporting is off until the selection is restored by URL.
                self.isRemappingSelection = true
                level.table.reloadData()
                self.layoutColumns()
                let rows = self.items(at: index)
                let restored = previous.compactMap { url in rows.firstIndex { $0.url == url } }
                level.table.selectRowIndexes(IndexSet(restored), byExtendingSelection: false)
                self.isRemappingSelection = false
                // When files the selection held are gone, the pane's mirror
                // is told, or Delete acts on files no longer on screen.
                if !previous.isEmpty, restored.count != previous.count,
                   index == self.levels.count - 1 {
                    self.onSelectMany?(restored.map { rows[$0].url })
                }
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
        icon.image = FileListViewController.icon(for: item)
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

    // Drag out
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = levelIndex(for: tableView) else { return nil }
        let rows = items(at: index)
        return rows.indices.contains(row) ? rows[row].url as NSURL : nil
    }

    // Drop in — a folder row is a target of its own; anywhere else in a column
    // is the folder that column lists.
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let index = levelIndex(for: tableView),
              let dragged = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !dragged.isEmpty else { return [] }

        let rows = items(at: index)
        if dropOperation == .on, rows.indices.contains(row), rows[row].opensAsFolder {
            if dragged.contains(rows[row].url) { return [] }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        tableView.setDropRow(-1, dropOperation: .on)
        let destination = levels[index].url.standardizedFileURL
        if dragged.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == destination }) { return [] }
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let index = levelIndex(for: tableView),
              let dragged = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !dragged.isEmpty else { return false }

        let move = info.draggingSourceOperationMask.contains(.move)
        let rows = items(at: index)
        let destination: URL
        if dropOperation == .on, rows.indices.contains(row), rows[row].opensAsFolder {
            destination = rows[row].url
        } else {
            destination = levels[index].url
        }
        onDropFiles?(dragged, destination, move)
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRemappingSelection,
              let table = notification.object as? NSTableView,
              let index = levelIndex(for: table)
        else { return }

        // A click on empty space or a ⌘-click deselect leaves selectedRow at
        // -1. Silence here left the pane's mirror holding the old URLs, and
        // Delete trashed files that looked deselected.
        if table.selectedRowIndexes.isEmpty {
            onSelectMany?([])
            return
        }

        guard items(at: index).indices.contains(table.selectedRow) else { return }

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
    /// here, so the box appeared to do nothing in this view. The selection is
    /// carried across the reload by URL: the table keeps selection by row
    /// number, and changing the filter renumbers the rows, so a bare reload
    /// moved the highlight onto whatever files took over those row numbers
    /// while the pane's mirror kept the old URLs.
    func applyFilter(_ text: String) {
        guard let level = levels.last else {
            filterText = text
            return
        }
        let index = levels.count - 1
        let before = items(at: index)
        let selected = level.table.selectedRowIndexes.compactMap {
            before.indices.contains($0) ? before[$0].url : nil
        }
        filterText = text
        // The flag goes up before the reload, not only around the reselect:
        // a filter that shrinks the row count below a selected index makes
        // reloadData trim the selection and post selectionDidChange
        // synchronously, and unsuppressed that runs the descend logic and
        // overwrites the pane's mirror mid-keystroke.
        isRemappingSelection = true
        level.table.reloadData()
        let after = items(at: index)
        let restored = selected.compactMap { url in after.firstIndex { $0.url == url } }
        level.table.selectRowIndexes(IndexSet(restored), byExtendingSelection: false)
        isRemappingSelection = false
        // The pane's mirror hears the selection as restored — always, since
        // the reload was suppressed and the trim may have already changed
        // what the table itself believes. When the browser is hidden the
        // pane is showing another view, and reporting would overwrite that
        // view's selection instead.
        if !isHidden {
            onSelectMany?(restored.map { after[$0].url })
        }
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

    /// Selects every unselected row of the deepest column and vice versa.
    func invertSelectionInDeepestColumn() {
        guard let level = levels.last else { return }
        let count = items(at: levels.count - 1).count
        var inverted = IndexSet(integersIn: 0..<count)
        inverted.subtract(level.table.selectedRowIndexes)
        level.table.selectRowIndexes(inverted, byExtendingSelection: false)
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

    /// Re-reads every column, for after a trash, a rename, or a settings
    /// change. In place: rebuilding through show() collapsed the whole path
    /// to one column and lost the drill-down on every reload the pane
    /// forwarded here. Reloading only the deepest was not enough either: a
    /// hidden-files or sort change reaches every column, and ancestors left
    /// alone kept drawing the old rows next to a column with the new ones.
    func refreshColumns() {
        guard !levels.isEmpty else { return }
        let urls = levels.map { $0.url }
        // The folder being refreshed may itself be what was trashed or
        // renamed; back out to the nearest ancestor column that still
        // exists. The existence check is file IO, and on a dead network
        // mount it blocks until the mount times out, so it runs off the
        // main thread like every other read in this view.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var keep = urls.count
            while keep > 1, !FileManager.default.fileExists(atPath: urls[keep - 1].path) {
                keep -= 1
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // A navigation while the check ran already rebuilt the
                // columns; acting on the stale answer here would tear the
                // new ones down, so this pass stands down instead.
                guard self.levels.map({ $0.url }) == urls else { return }
                if keep < self.levels.count {
                    // Dropping levels moves which column is deepest, and
                    // the filter applies only to the deepest, so it is
                    // cleared the same way every other depth change clears
                    // it. Kept, it would make loadColumn map the new
                    // deepest's selection through filtered rows the table
                    // never drew, and the highlight would land on files the
                    // user never picked.
                    self.clearFilterForDepthChange()
                    while self.levels.count > keep {
                        let level = self.levels.removeLast()
                        level.container.removeFromSuperview()
                        level.divider.removeFromSuperview()
                        level.message.removeFromSuperview()
                    }
                    self.layoutColumns()
                }
                for index in self.levels.indices {
                    self.loadColumn(at: index)
                }
            }
        }
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
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastX else { return }
        // Measured in window coordinates, which do not move with the view. A
        // delta measured against the divider's own coordinates counted the
        // divider's movement as pointer travel and fed it back into the next
        // event, which lurched every divider after the first.
        let now = event.locationInWindow.x
        lastX = now
        onDrag?(now - previous)
    }

    override func mouseUp(with event: NSEvent) {
        lastX = nil
    }
}
