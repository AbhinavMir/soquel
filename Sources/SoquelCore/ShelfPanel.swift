import AppKit

/// The shelf: files gathered from anywhere, held until you decide where they go.
///
/// Rows are plain views in a stack, like the transfer and compare panels — a
/// single-column table sizes its cells to the column rather than the window.
final class ShelfPanelController: NSWindowController {
    static let shared: ShelfPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Shelf"
        window.setFrameAutosaveName("SoquelShelf")
        window.level = .floating
        let controller = ShelfPanelController(window: window)
        controller.build()
        return controller
    }()

    /// Where "Copy Here" and "Move Here" put things. Set by the window that
    /// opened the panel and refreshed as the focused pane navigates.
    var destination: URL? {
        didSet { updateFooter() }
    }
    /// Called after a copy or move so the destination pane reloads.
    var onDelivered: (() -> Void)?

    private var rowStack: NSStackView!
    private var footer: NSTextField!
    private var copyButton: NSButton!
    private var moveButton: NSButton!
    private var observer: NSObjectProtocol?
    /// True from the click on Copy Here or Move Here until the transfer's
    /// completion runs. Status reports from the destination pane arrive
    /// throughout the transfer and refresh the footer; without the flag they
    /// would re-enable the buttons and invite a second, concurrent delivery
    /// of the same files.
    private var deliveryInFlight = false

    private func build() {
        rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        // An unflipped clip view puts the first row at the bottom of the panel.
        scroll.contentView = FlippedClipView()
        scroll.documentView = rowStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: Shelf.summary)
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        footer.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShelf))
        copyButton = NSButton(title: "Copy Here", target: self, action: #selector(copyHere))
        moveButton = NSButton(title: "Move Here", target: self, action: #selector(moveHere))
        copyButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [clear, moveButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            rowStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root

        observer = NotificationCenter.default.addObserver(
            forName: .soquelShelfChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func refresh() {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for url in Shelf.urls {
            let row = makeRow(for: url)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        updateFooter()
    }

    private func updateFooter() {
        guard footer != nil else { return }
        if deliveryInFlight {
            // The progress line stays until the completion writes the result.
            copyButton?.isEnabled = false
            moveButton?.isEnabled = false
            return
        }
        let empty = Shelf.isEmpty
        copyButton?.isEnabled = !empty && destination != nil
        moveButton?.isEnabled = !empty && destination != nil

        if empty {
            footer.stringValue = "The shelf is empty — add files with ⌃⌘A"
        } else if let destination {
            footer.stringValue = "\(Shelf.summary) → \(destination.lastPathComponent)"
        } else {
            footer.stringValue = Shelf.summary
        }
    }

    private func makeRow(for url: URL) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = Theme.rowName
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        // The folder is shown as well as the name: the point of the shelf is
        // that two files with the same name came from different places.
        let parent = NSTextField(labelWithString: url.deletingLastPathComponent().path)
        parent.font = Theme.rowSecondary
        parent.textColor = .secondaryLabelColor
        parent.lineBreakMode = .byTruncatingHead
        parent.toolTip = url.path
        parent.translatesAutoresizingMaskIntoConstraints = false

        let remove = NSButton(title: "✕", target: self, action: #selector(removeRow(_:)))
        remove.isBordered = false
        remove.identifier = NSUserInterfaceItemIdentifier(url.path)
        remove.toolTip = "Take off the shelf"
        remove.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, name, parent, remove] as [NSView] { container.addSubview(view) }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            parent.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            parent.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            parent.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),

            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            remove.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func removeRow(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        Shelf.remove(URL(fileURLWithPath: path))
    }

    @objc private func clearShelf(_ sender: Any?) {
        Shelf.clear()
    }

    @objc private func copyHere(_ sender: Any?) { deliver(moving: false) }
    @objc private func moveHere(_ sender: Any?) { deliver(moving: true) }

    /// Hands the shelf to the ordinary transfer engine, so conflicts, undo and
    /// the transfer queue all behave as they do for any other copy or move.
    private func deliver(moving: Bool) {
        guard let destination, !Shelf.isEmpty, !deliveryInFlight else { return }
        let urls = Shelf.urls
        deliveryInFlight = true
        copyButton.isEnabled = false
        moveButton.isEnabled = false
        footer.stringValue = "\(moving ? "Moving" : "Copying") \(urls.count) to \(destination.lastPathComponent)…"

        OperationEngine.shared.transfer(
            urls,
            to: destination,
            move: moving,
            resolveConflict: { [weak self] source, existing in
                self?.askConflict(source: source, existing: existing) ?? ConflictResolution(choice: .skip)
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.deliveryInFlight = false
                if moving {
                    UndoStack.shared.pushMove(result: result)
                    // Only the files that actually moved are gone from where
                    // the shelf pointed. Cancelled, skipped, and failed items
                    // are still at their sources, so they stay on the shelf.
                    for url in result.succeeded { Shelf.remove(url) }
                } else {
                    UndoStack.shared.pushCopy(result: result)
                }
                let moved = result.createdDestinations.count
                self.footer.stringValue = result.failures.isEmpty
                    ? "\(moving ? "Moved" : "Copied") \(moved) to \(destination.lastPathComponent)"
                    : "\(moving ? "Moved" : "Copied") \(moved), \(result.failures.count) failed"
                self.onDelivered?()
                self.refresh()
            }
        )
    }

    /// Conflicts are resolved here rather than deferred to the pane: the panel
    /// is the front window, and a sheet on a window behind it cannot be seen.
    private func askConflict(source: URL, existing: URL) -> ConflictResolution {
        let alert = NSAlert()
        alert.messageText = "“\(existing.lastPathComponent)” already exists"
        alert.informativeText = "in \(existing.deletingLastPathComponent().path)"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return ConflictResolution(choice: .keepBoth)
        case .alertSecondButtonReturn: return ConflictResolution(choice: .replace)
        case .alertThirdButtonReturn: return ConflictResolution(choice: .skip)
        default: return ConflictResolution(choice: .cancel)
        }
    }
}
