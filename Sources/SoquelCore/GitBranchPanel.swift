import AppKit

/// The branches in the repository you are standing in.
///
/// Reading is always available. Switching is behind Settings › General, and
/// says why when it refuses rather than doing something clever.
final class GitBranchPanelController: NSWindowController {
    static let shared: GitBranchPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Branches"
        window.setFrameAutosaveName("SoquelBranches")
        window.isReleasedWhenClosed = false
        let controller = GitBranchPanelController(window: window)
        controller.build()
        if !window.setFrameUsingName("SoquelBranches") { window.center() }
        return controller
    }()

    private var table: NSTableView!
    private var header: NSTextField!
    private var status: NSTextField!
    private var switchButton: NSButton!
    private var diffButton: NSButton!
    private var branches: [GitRepo.Branch] = []
    private var root: URL?

    private func build() {
        header = NSTextField(labelWithString: "")
        header.font = Theme.path
        header.lineBreakMode = .byTruncatingMiddle
        header.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(switchClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        diffButton = NSButton(title: "Diff with Current", target: self, action: #selector(diffClicked))
        switchButton = NSButton(title: "Switch", target: self, action: #selector(switchClicked))
        switchButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [diffButton, switchButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(status)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    func show(repository: URL) {
        _ = window
        root = repository
        header.stringValue = repository.path
        status.stringValue = GitRepo.actionsEnabled
            ? ""
            : "Switching branches is off. Settings › General turns it on."
        switchButton.isEnabled = GitRepo.actionsEnabled
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    private func reload() {
        guard let root else { return }
        GitRepo.branches(in: root) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let branches):
                self.branches = branches
                self.table.reloadData()
                if let current = branches.firstIndex(where: \.isCurrent) {
                    self.table.selectRowIndexes([current], byExtendingSelection: false)
                }
            case .failure(let error):
                self.branches = []
                self.table.reloadData()
                self.status.stringValue = error.localizedDescription
            }
        }
    }

    private var selected: GitRepo.Branch? {
        branches.indices.contains(table.selectedRow) ? branches[table.selectedRow] : nil
    }

    @objc private func switchClicked() {
        guard let root, let branch = selected else { return }
        guard !branch.isCurrent else {
            status.stringValue = "Already on \(branch.name)"
            return
        }
        status.stringValue = "Switching to \(branch.name)…"
        GitRepo.checkout(branch.name, in: root) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.status.stringValue = message
                self.reload()
                // Everything on screen is showing the old branch's files.
                NotificationCenter.default.post(name: .soquelSettingsChanged, object: nil)
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    @objc private func diffClicked() {
        guard let root, let branch = selected else { return }
        guard let current = branches.first(where: \.isCurrent) else { return }
        guard branch.name != current.name else {
            status.stringValue = "That is the current branch"
            return
        }
        status.stringValue = "Comparing \(current.name) with \(branch.name)…"
        GitRepo.diff(current.name, branch.name, in: root) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.status.stringValue = ""
                DiffPanelController.shared.show(
                    unified: text, title: "\(current.name) ⟷ \(branch.name)"
                )
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
            }
        }
    }
}

extension GitBranchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { branches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard branches.indices.contains(row) else { return nil }
        let branch = branches[row]

        let id = NSUserInterfaceItemIdentifier("branchRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let fresh = NSTableCellView()
            fresh.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            fresh.addSubview(field)
            fresh.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: fresh.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: fresh.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
            ])
            return fresh
        }()

        var text = branch.isCurrent ? "● \(branch.name)" : "   \(branch.name)"
        var trail: [String] = []
        if let ahead = branch.ahead, ahead > 0 { trail.append("↑\(ahead)") }
        if let behind = branch.behind, behind > 0 { trail.append("↓\(behind)") }
        if !trail.isEmpty { text += "  " + trail.joined(separator: " ") }

        cell.textField?.stringValue = text
        cell.textField?.font = branch.isCurrent ? Theme.pathCurrent : Theme.rowName
        cell.textField?.textColor = branch.isCurrent ? Theme.accent : .labelColor
        return cell
    }
}
