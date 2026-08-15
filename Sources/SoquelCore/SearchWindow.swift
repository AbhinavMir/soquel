import AppKit

/// The search panel: every option the engine supports is on screen, because an
/// option that exists but cannot be reached is the same as one that does not.
final class SearchWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var panel: NSPanel?
    private weak var owner: MainWindowController?
    private var root: URL = FileManager.default.homeDirectoryForCurrentUser

    private var field: NSSearchField!
    private var modeControl: NSSegmentedControl!
    private var scopeControl: NSSegmentedControl!
    private var matchingControl: NSPopUpButton!
    private var caseBox: NSButton!
    private var hiddenBox: NSButton!
    private var packagesBox: NSButton!
    private var gitignoreBox: NSButton!
    private var depthField: NSTextField!
    private var table: NSTableView!
    private var summaryLabel: NSTextField!

    private var hits: [FileSearch.Hit] = []
    private var search = FileSearch()
    /// Which startSearch the panel currently cares about. The engine lets a
    /// cancelled run keep reporting — that is deliberate, so a stop can say it
    /// stopped — but the panel clears its rows on every keystroke, and a
    /// flush queued by the previous query must not land in the new query's
    /// table. Deliveries carry the sequence they were started with and are
    /// dropped when it is stale.
    private var searchSequence = 0
    /// Re-runs a meaning search when the index lands, live only while the
    /// panel is open.
    private var indexObserver: NSObjectProtocol?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    func present(for controller: MainWindowController, mode: FileSearch.Mode, root: URL) {
        present(for: controller, mode: mode, root: root, preload: nil)
    }

    /// Opens the panel already filled in from a saved search and runs it.
    func present(for controller: MainWindowController, saved: SavedSearch, fallbackRoot: URL) {
        let query = saved.query(fallbackRoot: fallbackRoot)
        present(for: controller, mode: query.mode, root: query.root, preload: query)
    }

    private func present(
        for controller: MainWindowController,
        mode: FileSearch.Mode,
        root: URL,
        preload: FileSearch.Query?
    ) {
        guard let host = controller.window else { return }
        guard panel == nil else {
            field?.window?.makeFirstResponder(field)
            return
        }
        owner = controller
        self.root = root
        hits = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find"
        panel.minSize = NSSize(width: 640, height: 420)

        build(in: panel, mode: mode)
        self.panel = panel

        // The index loads and rebuilds in the background and posts when the
        // contents land. A meaning search run before that moment answered
        // "nothing is indexed yet"; re-running it turns that into the real
        // answer without the user typing again.
        indexObserver = NotificationCenter.default.addObserver(
            forName: .soquelIndexChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel != nil else { return }
            if self.currentQuery().mode == .meaning, !self.field.stringValue.isEmpty {
                self.startSearch()
            }
        }

        host.beginSheet(panel) { [weak self] _ in
            self?.search.cancel()
            if let observer = self?.indexObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.indexObserver = nil
            }
            self?.panel = nil
            self?.owner = nil
        }
        panel.makeFirstResponder(field)

        if let preload {
            apply(preload)
            startSearch()
        }
    }

    /// Fills every control from a query, so a saved search reopens exactly as
    /// it was saved rather than as a text box with the words in it.
    private func apply(_ query: FileSearch.Query) {
        field.stringValue = query.text
        modeControl.selectedSegment = FileSearch.Mode.allCases.firstIndex(of: query.mode) ?? 0
        scopeControl.selectedSegment = FileSearch.Scope.allCases.firstIndex(of: query.scope) ?? 0
        matchingControl.selectItem(at: FileSearch.Matching.allCases.firstIndex(of: query.matching) ?? 0)
        caseBox.state = query.caseSensitive ? .on : .off
        hiddenBox.state = query.includeHidden ? .on : .off
        packagesBox.state = query.includePackages ? .on : .off
        gitignoreBox.state = query.respectGitignore ? .on : .off
        depthField.stringValue = query.maximumDepth.map(String.init) ?? ""
        root = query.root
    }

    /// Saves the panel's current settings under a name, for the sidebar.
    @objc private func saveSearch(_ sender: Any?) {
        guard let panel, !field.stringValue.isEmpty else {
            NSSound.beep()
            return
        }
        let nameField = NSTextField(string: field.stringValue)
        nameField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        let alert = NSAlert()
        alert.messageText = "Save this search"
        alert.informativeText = "It appears under Searches in the sidebar and re-runs when you pick it."
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: panel) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            SavedSearchStore.save(SavedSearch(name: name, query: self.currentQuery()))
        }
    }

    private func build(in panel: NSPanel, mode: FileSearch.Mode) {
        field = NSSearchField()
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        modeControl = NSSegmentedControl(
            labels: FileSearch.Mode.allCases.map(\.title),
            trackingMode: .selectOne, target: self, action: #selector(optionsChanged)
        )
        modeControl.selectedSegment = FileSearch.Mode.allCases.firstIndex(of: mode) ?? 0

        scopeControl = NSSegmentedControl(
            labels: [root.lastPathComponent.isEmpty ? "This folder" : root.lastPathComponent, "Home", "Everywhere"],
            trackingMode: .selectOne, target: self, action: #selector(optionsChanged)
        )
        scopeControl.selectedSegment = 0

        matchingControl = NSPopUpButton()
        matchingControl.addItems(withTitles: FileSearch.Matching.allCases.map(\.title))
        matchingControl.target = self
        matchingControl.action = #selector(optionsChanged)

        caseBox = checkbox("Match case", on: false)
        // On by default: hiding dotfiles from a search someone deliberately ran
        // is the loudest complaint about Finder's search.
        hiddenBox = checkbox("Include hidden files", on: true)
        packagesBox = checkbox("Look inside app bundles", on: true)
        // Off by default. Hiding results is what this search exists to avoid,
        // so skipping ignored files is asked for rather than assumed.
        gitignoreBox = checkbox("Skip files ignored by .gitignore", on: false)

        depthField = NSTextField()
        depthField.placeholderString = "Any"
        depthField.target = self
        depthField.action = #selector(optionsChanged)
        depthField.translatesAutoresizingMaskIntoConstraints = false
        depthField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let depthRow = NSStackView(views: [label("Depth"), depthField, label("levels")])
        depthRow.orientation = .horizontal
        depthRow.spacing = 6

        let optionsRow = NSStackView(views: [caseBox, hiddenBox, packagesBox, gitignoreBox, depthRow])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 14
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save Search…", target: self, action: #selector(saveSearch(_:)))

        let controlRow = NSStackView(views: [modeControl, matchingControl, scopeControl, saveButton])
        controlRow.orientation = .horizontal
        controlRow.spacing = 10
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 40
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.target = self
        table.doubleAction = #selector(revealSelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.width = 720
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel = NSTextField(labelWithString: "Type to search. Results stream in as they are found.")
        summaryLabel.font = Theme.status
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for subview in [field, controlRow, optionsRow, scroll, summaryLabel] as [NSView] {
            content.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            controlRow.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            controlRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            optionsRow.topAnchor.constraint(equalTo: controlRow.bottomAnchor, constant: 8),
            optionsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -6),

            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            summaryLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    private func checkbox(_ title: String, on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionsChanged))
        box.state = on ? .on : .off
        return box
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func dismiss() {
        guard let panel, let host = panel.sheetParent else { return }
        search.cancel()
        host.endSheet(panel)
    }

    @objc private func optionsChanged() { startSearch() }

    func controlTextDidChange(_ obj: Notification) { startSearch() }

    private func currentQuery() -> FileSearch.Query {
        var query = FileSearch.Query(text: field.stringValue, root: root)
        query.mode = FileSearch.Mode.allCases[max(0, modeControl.selectedSegment)]
        query.scope = FileSearch.Scope.allCases[max(0, scopeControl.selectedSegment)]
        query.matching = FileSearch.Matching.allCases[max(0, matchingControl.indexOfSelectedItem)]
        query.caseSensitive = caseBox.state == .on
        query.includeHidden = hiddenBox.state == .on
        query.includePackages = packagesBox.state == .on
        query.respectGitignore = gitignoreBox.state == .on
        let depth = Int(depthField.stringValue.trimmingCharacters(in: .whitespaces))
        query.maximumDepth = (depth ?? 0) > 0 ? depth : nil
        return query
    }

    private func startSearch() {
        search.cancel()
        // A fresh engine per run, not just a fresh generation. The engine's
        // queue is serial, and a walk stuck inside a filesystem call on an
        // unresponsive network mount only observes the cancel when that call
        // returns, which can take minutes. Reusing the instance would queue
        // this run behind the stuck one; a new instance starts immediately,
        // and the sequence guard below drops whatever the abandoned walk
        // still delivers.
        search = FileSearch()
        searchSequence += 1
        let sequence = searchSequence
        hits = []
        table.reloadData()

        let query = currentQuery()
        guard !query.text.isEmpty else {
            summaryLabel.textColor = .secondaryLabelColor
            summaryLabel.stringValue = "Type to search. Results stream in as they are found."
            return
        }

        // A regular expression that does not compile is reported rather than
        // quietly matching nothing. Meaning mode never builds a matcher — the
        // text is embedded, not compiled — so the matching setting cannot
        // block it.
        if query.mode != .meaning, case .failure(let error) = FileSearch.compile(query) {
            summaryLabel.textColor = Theme.danger
            summaryLabel.stringValue = "Pattern error: \(error.localizedDescription)"
            return
        }

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.stringValue = "Searching \(query.scope.title.lowercased())…"

        search.run(query) { [weak self] batch in
            guard let self, sequence == self.searchSequence else { return }
            self.hits.append(contentsOf: batch)
            // Keep the best matches on top as later batches arrive.
            self.hits.sort { $0.rank < $1.rank }
            self.table.reloadData()
            self.summaryLabel.stringValue = "\(self.hits.count) found, still searching…"
        } finished: { [weak self] summary in
            guard let self, sequence == self.searchSequence, !summary.cancelled else { return }
            var text = summary.found == 0
                ? "No matches in \(summary.examined) items"
                : "\(summary.found) of \(summary.examined) items matched"
            // Say what was not looked at, so "nothing" can be told apart from
            // "I did not look there".
            if !summary.caveats.isEmpty { text += " — " + summary.caveats.joined(separator: ", ") }
            self.summaryLabel.stringValue = text
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            revealSelected()
            return true
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        default:
            return false
        }
    }

    private func move(by delta: Int) {
        guard !hits.isEmpty else { return }
        let next = max(0, min(hits.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Opens the containing folder in the focused pane and selects the hit, so
    /// every ordinary command applies to it.
    @objc private func revealSelected() {
        let row = table.selectedRow
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        let controller = owner
        dismiss()
        controller?.reveal(hit.url)
    }

    // MARK: - Results

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let hit = hits[row]

        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: hit.url.lastPathComponent)
        title.font = Theme.rowName
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: hit.excerpt ?? hit.url.deletingLastPathComponent().path)
        detail.font = Theme.rowNumeric
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: hit.url.path)
        icon.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.textField = title

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
        ])
        return cell
    }
}
