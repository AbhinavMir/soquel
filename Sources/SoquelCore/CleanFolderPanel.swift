import AppKit

/// Clean This Folder, in two deliberate halves.
///
/// First what would be sent, because this is the one feature that sends the
/// contents of files off the machine. Then what would be moved, ticked row by
/// row. Neither half happens on its own.
final class CleanFolderPanelController: NSWindowController {
    private let folder: URL
    private weak var host: MainWindowController?

    private var payload: CleanSanitiser.Payload!
    private var plan: CleanFolder.Plan?
    private var chosen = Set<String>()
    /// Held while its sheet is up; a window controller with nothing referring
    /// to it is released and takes the sheet with it.
    private var pickerHolder: ProviderPickerController?
    /// Held while it is up, so it can be ended by its own button.
    private var sentSheet: NSWindow?

    private var headline: NSTextField!
    private var detail: NSTextField!
    private var table: NSTableView!
    private var spinner: NSProgressIndicator!
    private var goButton: NSButton!
    private var showSendButton: NSButton!

    init(folder: URL, host: MainWindowController?) {
        self.folder = folder
        self.host = host
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Clean “\(folder.lastPathComponent)”"
        window.minSize = NSSize(width: 560, height: 380)
        window.maxSize = NSSize(width: 1000, height: 900)
        super.init(window: window)
        PrivacyScreen.apply(to: window)
        build()
        gather()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        headline = NSTextField(labelWithString: "Reading the folder…")
        headline.font = Theme.rowName
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 2
        // Without this a wrapping label's intrinsic width is the whole string,
        // and the window grows to fit it rather than the text wrapping. The
        // panel opened 1087 points wide instead of 720.
        headline.preferredMaxLayoutWidth = 640
        headline.translatesAutoresizingMaskIntoConstraints = false

        detail = NSTextField(labelWithString: "")
        detail.font = Theme.rowSecondary
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 6
        detail.preferredMaxLayoutWidth = 660
        detail.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step")))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        showSendButton = NSButton(title: "Show What Would Be Sent",
                                  target: self, action: #selector(showWhatWouldBeSent))
        showSendButton.translatesAutoresizingMaskIntoConstraints = false

        goButton = NSButton(title: "Suggest an Arrangement",
                            target: self, action: #selector(suggest))
        goButton.keyEquivalent = "\r"
        goButton.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Close", target: self, action: #selector(dismiss))
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false

        [headline, detail, spinner, scroll, showSendButton, goButton, close].forEach(content.addSubview)
        window?.contentView = content

        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            headline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            headline.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),

            spinner.centerYAnchor.constraint(equalTo: headline.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: goButton.topAnchor, constant: -12),

            showSendButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            showSendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            goButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            goButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            close.trailingAnchor.constraint(equalTo: goButton.leadingAnchor, constant: -10),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Reading

    private func gather() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let payload = CleanSanitiser.gather(self.folder)
            DispatchQueue.main.async {
                self.payload = payload
                let files = payload.entries.filter { !$0.isDirectory }.count
                let folders = payload.entries.filter(\.isDirectory).count
                self.headline.stringValue =
                    "\(files) file\(files == 1 ? "" : "s") and \(folders) folder\(folders == 1 ? "" : "s"). "
                    + "\(payload.bytes / 1000) KB would be sent."
                self.detail.stringValue = payload.notes.joined(separator: " ")
                self.goButton.isEnabled = files > 0
            }
        }
    }

    @objc private func showWhatWouldBeSent() {
        let text = CleanSanitiser.preview(payload)
        // A sheet on this window, not a modal session of its own. It used to
        // call NSApp.runModal(for:) on a window with no button that called
        // stopModal, so the session never ended: the sheet could not be
        // dismissed, and every other control in the application beeped because
        // the modal session was swallowing the events. The application had to
        // be force quit.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                             styleMask: [.titled, .resizable],
                             backing: .buffered, defer: false)
        sheet.title = "What would be sent"
        PrivacyScreen.apply(to: sheet)

        let view = NSTextView()
        view.string = text.isEmpty ? "Nothing would be sent." : text
        view.isEditable = false
        view.isSelectable = true
        view.font = Theme.rowNumeric
        view.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Close", target: self, action: #selector(closeWhatWouldBeSent))
        close.keyEquivalent = "\r"
        close.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(close)
        sheet.contentView = content
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -10),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        sentSheet = sheet
        window?.beginSheet(sheet) { [weak self] _ in self?.sentSheet = nil }
    }

    @objc private func closeWhatWouldBeSent() {
        guard let sentSheet else { return }
        window?.endSheet(sentSheet)
    }

    // MARK: - Asking

    @objc private func suggest() {
        let ready = LLMProvider.isReady()
        guard ready.ok else { return pickProvider() }
        goButton.isEnabled = false
        spinner.startAnimation(nil)
        headline.stringValue = "Asking…"
        CleanFolder.propose(folder: folder, payload: payload) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.goButton.isEnabled = true
            switch result {
            case .failure(let error):
                self.headline.stringValue = "No arrangement was suggested"
                self.detail.stringValue = error.localizedDescription
                if case CleanFolder.Failure.notReady = error { self.pickProvider() }
            case .success(let plan):
                self.plan = plan
                self.chosen = Set(plan.usable.map(\.source.path))
                self.headline.stringValue = plan.summary
                let blocked = plan.steps.count - plan.usable.count
                self.detail.stringValue = blocked == 0
                    ? "\(plan.usable.count) move\(plan.usable.count == 1 ? "" : "s"). Untick anything you do not want. Nothing has moved yet."
                    : "\(plan.usable.count) move\(plan.usable.count == 1 ? "" : "s"), and \(blocked) that cannot be used. Nothing has moved yet."
                self.goButton.title = "Move the Ticked Files"
                self.goButton.action = #selector(self.apply)
                self.table.reloadData()
            }
        }
    }

    /// Asks where to send the question, with the icons, and carries straight
    /// on once something is chosen.
    private func pickProvider() {
        let picker = ProviderPickerController { [weak self] chose in
            guard chose else { return }
            self?.suggest()
        }
        guard let sheet = picker.window, let parent = window else { return }
        pickerHolder = picker
        parent.beginSheet(sheet) { [weak self] _ in self?.pickerHolder = nil }
    }

    // MARK: - Moving

    @objc private func apply() {
        guard let plan else { return }
        let steps = plan.usable.filter { chosen.contains($0.source.path) }
        guard !steps.isEmpty else { NSSound.beep(); return }

        // Folders the plan invents have to exist before anything moves into
        // them, and a folder that cannot be made takes its steps out rather
        // than leaving the move to fail one file at a time.
        var usable: [CleanFolder.Step] = []
        for step in steps {
            let parent = step.destination.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                usable.append(step)
            } catch {
                Log.info(.app, "clean: could not make \(parent.path): \(error.localizedDescription)")
            }
        }

        var moved: [(URL, URL)] = []
        var failures: [String] = []
        for step in usable {
            do {
                try FileManager.default.moveItem(at: step.source, to: step.destination)
                moved.append((step.source, step.destination))
            } catch {
                failures.append("\(step.source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // One undo for the whole clean, not one per file.
        UndoStack.shared.pushMove(sources: moved.map(\.0), destinations: moved.map(\.1))
        Log.info(.app, "clean: moved \(moved.count), failed \(failures.count) in \(folder.path)")

        host?.refreshAllPanes()
        dismiss()

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(moved.count) moved, \(failures.count) did not"
            alert.informativeText = failures.prefix(6).joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc private func dismiss() {
        window?.sheetParent?.endSheet(window!) ?? window?.close()
    }

    @objc fileprivate func tickChanged(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if sender.state == .on { chosen.insert(path) } else { chosen.remove(path) }
    }
}

extension CleanFolderPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { plan?.steps.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let step = plan?.steps[row] else { return nil }
        let view = NSView()

        let tick = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickChanged(_:)))
        tick.identifier = NSUserInterfaceItemIdentifier(step.source.path)
        tick.state = chosen.contains(step.source.path) ? .on : .off
        tick.isEnabled = step.problem == nil
        tick.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: step.source.lastPathComponent)
        name.font = Theme.rowName
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let where_ = NSTextField(labelWithString: describe(step))
        where_.font = Theme.rowSecondary
        where_.textColor = step.problem == nil ? .secondaryLabelColor : Theme.danger
        where_.lineBreakMode = .byTruncatingMiddle
        where_.translatesAutoresizingMaskIntoConstraints = false

        [tick, name, where_].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            tick.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            name.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            where_.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            where_.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            where_.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
        return view
    }

    private func describe(_ step: CleanFolder.Step) -> String {
        if let problem = step.problem { return problem }
        let target = step.destination.deletingLastPathComponent()
        let place = target == folder ? "stays here" : "→ \(target.lastPathComponent)/"
        let renamed = step.source.lastPathComponent == step.destination.lastPathComponent
            ? "" : ", renamed “\(step.destination.lastPathComponent)”"
        return step.reason.isEmpty ? place + renamed : "\(place)\(renamed) — \(step.reason)"
    }
}
