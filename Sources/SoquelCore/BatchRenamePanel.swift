import AppKit

/// The batch rename sheet: build rules, watch the preview update, then apply.
///
/// The preview is the point. Every name is shown before and after, and anything
/// that would collide is called out rather than discovered afterwards.
final class BatchRenameController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var panel: NSPanel?
    private weak var owner: MainWindowController?
    private var urls: [URL] = []
    private var previews: [RenamePreview] = []

    private var ruleControl: NSPopUpButton!
    private var firstField: NSTextField!
    private var secondField: NSTextField!
    private var firstLabel: NSTextField!
    private var secondLabel: NSTextField!
    private var regexBox: NSButton!
    private var caseBox: NSButton!
    private var table: NSTableView!
    private var summary: NSTextField!
    private var applyButton: NSButton!

    private enum RuleKind: String, CaseIterable {
        case findReplace, prefix, suffix, sequence, resequence, changeCase, replaceExtension, trim, date

        var title: String {
            switch self {
            case .findReplace: return "Find and replace"
            case .prefix: return "Add prefix"
            case .suffix: return "Add suffix"
            case .sequence: return "Sequential numbering"
            case .resequence: return "Renumber (keep the names)"
            case .changeCase: return "Change case"
            case .replaceExtension: return "Replace extension"
            case .trim: return "Trim whitespace"
            case .date: return "Insert file date"
            }
        }
    }

    func present(for controller: MainWindowController, urls: [URL]) {
        guard let host = controller.window, panel == nil, !urls.isEmpty else { return }
        owner = controller
        self.urls = urls

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "Rename \(urls.count) item\(urls.count == 1 ? "" : "s")"
        build(in: panel)
        self.panel = panel

        host.beginSheet(panel) { [weak self] _ in
            self?.panel = nil
            self?.owner = nil
        }
        refresh()
    }

    private func build(in panel: NSPanel) {
        ruleControl = NSPopUpButton()
        ruleControl.addItems(withTitles: RuleKind.allCases.map(\.title))
        ruleControl.target = self
        ruleControl.action = #selector(ruleChanged)

        firstLabel = label("Find")
        secondLabel = label("Replace with")

        firstField = NSTextField()
        firstField.delegate = self
        firstField.translatesAutoresizingMaskIntoConstraints = false
        firstField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        secondField = NSTextField()
        secondField.delegate = self
        secondField.translatesAutoresizingMaskIntoConstraints = false
        secondField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        regexBox = NSButton(checkboxWithTitle: "Regular expression", target: self, action: #selector(refresh))
        caseBox = NSButton(checkboxWithTitle: "Match case", target: self, action: #selector(refresh))

        let controls = NSStackView(views: [ruleControl, firstLabel, firstField, secondLabel, secondField])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let options = NSStackView(views: [regexBox, caseBox])
        options.orientation = .horizontal
        options.spacing = 14
        options.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        // The rows are a preview and nothing acts on one, so a selection
        // would only promise something. Without a filled selection the
        // labels keep their own colours and none needs to be the cell's
        // text field to be inverted.
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = 680
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        summary = NSTextField(labelWithString: "")
        summary.font = Theme.status
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false

        applyButton = NSButton(title: "Rename", target: self, action: #selector(applyRename))
        applyButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        let buttons = NSStackView(views: [cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [controls, options, scroll, summary, buttons] as [NSView] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            options.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            options.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summary.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        ruleChanged()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private var selectedKind: RuleKind {
        RuleKind.allCases[max(0, ruleControl.indexOfSelectedItem)]
    }

    /// Only the fields a rule actually uses are shown, labelled for that rule.
    @objc private func ruleChanged() {
        switch selectedKind {
        case .findReplace:
            firstLabel.stringValue = "Find"; secondLabel.stringValue = "Replace with"
            setFieldsVisible(first: true, second: true, options: true)
        case .prefix:
            firstLabel.stringValue = "Prefix"
            setFieldsVisible(first: true, second: false, options: false)
        case .suffix:
            firstLabel.stringValue = "Suffix"
            setFieldsVisible(first: true, second: false, options: false)
        case .sequence:
            firstLabel.stringValue = "Name"; secondLabel.stringValue = "Start at"
            if secondField.stringValue.isEmpty { secondField.stringValue = "1" }
            setFieldsVisible(first: true, second: true, options: false)
        case .resequence:
            firstLabel.stringValue = "Start at"; secondLabel.stringValue = "Digits (0 keeps each)"
            if firstField.stringValue.isEmpty { firstField.stringValue = "1" }
            if secondField.stringValue.isEmpty { secondField.stringValue = "0" }
            setFieldsVisible(first: true, second: true, options: false)
        case .changeCase:
            firstLabel.stringValue = "Style (lower, upper, title)"
            if firstField.stringValue.isEmpty { firstField.stringValue = "lower" }
            setFieldsVisible(first: true, second: false, options: false)
        case .replaceExtension:
            firstLabel.stringValue = "New extension"
            setFieldsVisible(first: true, second: false, options: false)
        case .trim:
            setFieldsVisible(first: false, second: false, options: false)
        case .date:
            firstLabel.stringValue = "Format"
            if firstField.stringValue.isEmpty { firstField.stringValue = "yyyy-MM-dd" }
            setFieldsVisible(first: true, second: false, options: false)
        }
        refresh()
    }

    private func setFieldsVisible(first: Bool, second: Bool, options: Bool) {
        firstLabel.isHidden = !first
        firstField.isHidden = !first
        secondLabel.isHidden = !second
        secondField.isHidden = !second
        regexBox.isHidden = !options
        caseBox.isHidden = !options
    }

    private func currentRule() -> RenameRule? {
        let first = firstField.stringValue
        let second = secondField.stringValue
        switch selectedKind {
        case .findReplace:
            guard !first.isEmpty else { return nil }
            return .findReplace(find: first, replace: second,
                                regex: regexBox.state == .on, caseSensitive: caseBox.state == .on)
        case .prefix:
            guard !first.isEmpty else { return nil }
            return .addPrefix(first)
        case .suffix:
            guard !first.isEmpty else { return nil }
            return .addSuffix(first)
        case .sequence:
            let start = Int(second) ?? 1
            return .sequence(prefix: first, start: start, padding: max(2, String(urls.count).count))
        case .resequence:
            return .resequence(start: Int(first) ?? 1, padding: Int(second) ?? 0)
        case .changeCase:
            let style = RenameRule.Case(rawValue: first.lowercased()) ?? .lower
            return .changeCase(style)
        case .replaceExtension:
            guard !first.isEmpty else { return nil }
            return .replaceExtension(first)
        case .trim:
            return .trimWhitespace
        case .date:
            return .insertDate(format: first, useCreated: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func refresh() {
        let rules = currentRule().map { [$0] } ?? []
        previews = BatchRename.plan(for: urls, rules: rules)
        table.reloadData()

        let changing = previews.filter { $0.changed && $0.problem == nil }.count
        let problems = previews.filter { $0.problem != nil }.count
        applyButton.isEnabled = changing > 0

        if problems > 0 {
            summary.stringValue = "\(changing) to rename, \(problems) blocked"
            summary.textColor = Theme.danger
        } else {
            summary.stringValue = changing == 0 ? "No changes" : "\(changing) to rename"
            summary.textColor = .secondaryLabelColor
        }
    }

    @objc private func dismiss() {
        guard let panel, let host = panel.sheetParent else { return }
        host.endSheet(panel)
    }

    @objc private func applyRename() {
        let result = BatchRename.apply(previews)
        UndoStack.shared.pushBatchRename(result.renamed)
        let controller = owner
        dismiss()

        if !result.failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Could not rename \(result.failures.count) item\(result.failures.count == 1 ? "" : "s")"
            alert.informativeText = result.failures.prefix(8)
                .map { "\($0.0.lastPathComponent): \($0.1.localizedDescription)" }
                .joined(separator: "\n")
            alert.runModal()
        }
        controller?.refreshAllPanes()
    }

    // MARK: - Preview rows

    func numberOfRows(in tableView: NSTableView) -> Int { previews.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previews.indices.contains(row) else { return nil }
        let preview = previews[row]

        // A plain cell view. FileCellView lays its text field out by hand,
        // from the leading edge across the whole width, so making the new
        // name its text field drew it on top of the old one and left the
        // slot after the arrow empty. With no text field set, the three
        // labels sit where the constraints below put them.
        let cell = NSTableCellView()
        let before = NSTextField(labelWithString: preview.original)
        before.font = Theme.rowNumeric
        before.textColor = .secondaryLabelColor
        before.lineBreakMode = .byTruncatingMiddle
        before.translatesAutoresizingMaskIntoConstraints = false

        let arrow = NSTextField(labelWithString: "→")
        arrow.textColor = .tertiaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        let after = NSTextField(labelWithString: preview.problem ?? preview.proposed)
        after.font = Theme.rowName
        after.textColor = preview.problem != nil
            ? Theme.danger
            : (preview.changed ? .labelColor : .tertiaryLabelColor)
        after.lineBreakMode = .byTruncatingMiddle
        after.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(before)
        cell.addSubview(arrow)
        cell.addSubview(after)

        NSLayoutConstraint.activate([
            before.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            before.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            before.widthAnchor.constraint(equalTo: cell.widthAnchor, multiplier: 0.42),

            arrow.leadingAnchor.constraint(equalTo: before.trailingAnchor, constant: 8),
            arrow.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            after.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 8),
            after.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            after.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
