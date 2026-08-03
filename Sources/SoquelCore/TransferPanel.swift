import AppKit

/// A clip view with the origin at the top, so content stacks downwards from
/// the first row rather than sitting on the floor of the scroll view.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The transfer queue: what is copying, how fast, and the controls to stop it.
final class TransferPanelController: NSWindowController {
    static let shared: TransferPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Transfers"
        window.setFrameAutosaveName("SoquelTransfers")
        window.level = .floating
        let controller = TransferPanelController(window: window)
        controller.build()
        return controller
    }()

    private var rowStack: NSStackView!
    private var footer: NSTextField!
    private var observer: NSObjectProtocol?
    private var ticker: Timer?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    fileprivate func build() {
        // Not an NSTableView. A single-column table sizes its cells to the
        // column rather than the scroll view, which left every row's contents
        // bunched against the left edge; three attempts to make the column fill
        // the panel all failed. Jobs number in the tens, so cell reuse buys
        // nothing, and a stack of plain views is laid out correctly for free.
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
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        footer = NSTextField(labelWithString: "No transfers")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear Finished", target: self, action: #selector(clearFinished))
        let cancelAll = NSButton(title: "Cancel All", target: self, action: #selector(cancelAll))
        let buttons = NSStackView(views: [clear, cancelAll])
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

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root

        observer = NotificationCenter.default.addObserver(
            forName: TransferQueue.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        ticker?.invalidate()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        startTicking()
    }

    /// Throughput and time-remaining change without any queue event, so the rows
    /// are redrawn on a timer while something is running — and only then.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            guard TransferQueue.shared.activeCount > 0 else { return }
            self.refresh()
        }
    }

    private func refresh() {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for job in TransferQueue.shared.jobs {
            let row = makeRow(for: job)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        let active = TransferQueue.shared.activeCount
        let total = TransferQueue.shared.jobs.count
        footer.stringValue = total == 0
            ? "No transfers"
            : "\(active) running, \(total - active) finished"
    }

    @objc private func clearFinished() {
        TransferQueue.shared.clearFinished()
    }

    @objc private func cancelAll() {
        TransferQueue.shared.cancelAll()
    }

    @objc private func retryJob(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let job = TransferQueue.shared.job(id: id)
        else { return }
        let retried = TransferQueue.shared.retryFailures(of: job)
        if retried.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Nothing left to retry"
            alert.informativeText = "The files that failed are no longer where they were."
            alert.runModal()
        }
    }

    @objc private func reorderJob(_ sender: NSSegmentedControl) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let index = TransferQueue.shared.jobs.firstIndex(where: { $0.id == id })
        else { return }
        let target = sender.selectedSegment == 0 ? index - 1 : index + 2
        TransferQueue.shared.move(id: id, to: max(0, target))
    }

    @objc private func togglePause(_ sender: NSButton) {
        guard let job = TransferQueue.shared.jobs.first(where: { $0.id.uuidString == sender.identifier?.rawValue })
        else { return }
        if job.state == .paused { job.resume() } else { job.pause() }
        TransferQueue.shared.notify()
    }

    @objc private func cancelJob(_ sender: NSButton) {
        guard let job = TransferQueue.shared.jobs.first(where: { $0.id.uuidString == sender.identifier?.rawValue })
        else { return }
        job.cancel()
        TransferQueue.shared.notify()
    }

    // MARK: - Rows

    private func makeRow(for job: TransferJob) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: job.title)
        title.font = Theme.rowName
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: job.statusLine(formatter: Self.byteFormatter))
        status.font = Theme.rowNumeric
        status.textColor = job.state == .failed ? Theme.danger : .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSProgressIndicator()
        bar.isIndeterminate = job.totalBytes == 0 && job.state == .running
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = job.fractionComplete
        if bar.isIndeterminate { bar.startAnimation(nil) }
        bar.translatesAutoresizingMaskIntoConstraints = false

        let pause = NSButton(
            image: NSImage(systemSymbolName: job.state == .paused ? "play.fill" : "pause.fill",
                           accessibilityDescription: job.state == .paused ? "Resume" : "Pause") ?? NSImage(),
            target: self, action: #selector(togglePause(_:))
        )
        pause.identifier = NSUserInterfaceItemIdentifier(job.id.uuidString)
        pause.isBordered = false
        pause.isEnabled = job.isActive
        pause.translatesAutoresizingMaskIntoConstraints = false

        let stop = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") ?? NSImage(),
            target: self, action: #selector(cancelJob(_:))
        )
        stop.identifier = NSUserInterfaceItemIdentifier(job.id.uuidString)
        stop.isBordered = false
        stop.isEnabled = job.isActive
        stop.translatesAutoresizingMaskIntoConstraints = false

        // A job that failed some of its files can put just those back on the
        // queue, rather than the whole copy being redone by hand.
        let retry = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry failed") ?? NSImage(),
            target: self, action: #selector(retryJob(_:))
        )
        retry.identifier = NSUserInterfaceItemIdentifier(job.id.uuidString)
        retry.isBordered = false
        retry.isHidden = job.failures.isEmpty || job.isActive
        retry.toolTip = job.failures.count == 1
            ? "Try the 1 file that failed again"
            : "Try the \(job.failures.count) files that failed again"
        retry.translatesAutoresizingMaskIntoConstraints = false

        let move = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up") ?? NSImage(),
                NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down") ?? NSImage(),
            ],
            trackingMode: .momentary, target: self, action: #selector(reorderJob(_:))
        )
        move.identifier = NSUserInterfaceItemIdentifier(job.id.uuidString)
        move.segmentStyle = .smallSquare
        // Only a waiting job can be reordered; one already moving bytes cannot
        // be un-started by putting it lower in a list.
        move.isHidden = job.state != .waiting
        move.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, bar, status, pause, stop, retry, move] as [NSView] { container.addSubview(view) }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 62),

            retry.trailingAnchor.constraint(equalTo: pause.leadingAnchor, constant: -2),
            retry.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            retry.widthAnchor.constraint(equalToConstant: 24),

            move.trailingAnchor.constraint(equalTo: retry.leadingAnchor, constant: -2),
            move.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            stop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stop.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 24),

            pause.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -2),
            pause.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pause.widthAnchor.constraint(equalToConstant: 24),

            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: move.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            bar.heightAnchor.constraint(equalToConstant: 6),

            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
        ])
        return container
    }
}
