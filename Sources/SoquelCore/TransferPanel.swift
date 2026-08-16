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
    /// The row on screen for each job, held so a refresh can update it rather
    /// than build a new one.
    private var rowsByJob: [UUID: TransferRow] = [:]

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
        let jobs = TransferQueue.shared.jobs
        syncRows(to: jobs)
        for job in jobs { rowsByJob[job.id]?.update(with: job, formatter: Self.byteFormatter) }
        let active = TransferQueue.shared.activeCount
        let total = jobs.count
        footer.stringValue = total == 0
            ? "No transfers"
            : "\(active) running, \(total - active) finished"
    }

    /// Makes the stack hold one row per job, in queue order, keeping every row
    /// that is already there.
    ///
    /// The rows used to be thrown away and rebuilt on each notify, and the
    /// timer notifies twice a second while a copy runs, so the accessibility
    /// tree changed under any client that was reading it: VoiceOver and
    /// System Events reported an invalid index for the Pause and Cancel
    /// buttons, and a press that did land went to a view that was no longer
    /// in the window and so did nothing. Only a job leaving the queue or the
    /// queue being reordered touches the stack now.
    private func syncRows(to jobs: [TransferJob]) {
        var wanted: [TransferRow] = []
        for job in jobs {
            if let existing = rowsByJob[job.id] {
                wanted.append(existing)
            } else {
                let row = makeRow(for: job)
                rowsByJob[job.id] = row
                wanted.append(row)
            }
        }
        let live = Set(jobs.map(\.id))
        rowsByJob = rowsByJob.filter { live.contains($0.key) }

        let current = rowStack.arrangedSubviews
        let matches = current.count == wanted.count
            && zip(current, wanted).allSatisfy { pair in pair.0 === pair.1 }
        guard !matches else { return }

        for view in current {
            (view as? TransferRow)?.widthMatch?.isActive = false
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in wanted {
            rowStack.addArrangedSubview(row)
            // A fresh constraint each time: the old one refers to a pair of
            // views that no longer share an ancestor, so Auto Layout drops it.
            let width = row.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
            width.isActive = true
            row.widthMatch = width
        }
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

    private func makeRow(for job: TransferJob) -> TransferRow {
        TransferRow(
            jobID: job.id, target: self,
            pauseAction: #selector(togglePause(_:)),
            cancelAction: #selector(cancelJob(_:)),
            retryAction: #selector(retryJob(_:)),
            reorderAction: #selector(reorderJob(_:))
        )
    }
}

/// One job's row in the transfer panel.
///
/// The views are built once and given new values on each refresh. They used
/// to be rebuilt from scratch, which replaced the row's accessibility
/// elements several times a second while a copy ran.
final class TransferRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let pause: NSButton
    private let stop: NSButton
    /// A job that failed some of its files can put just those back on the
    /// queue, rather than the whole copy being redone by hand.
    private let retry: NSButton
    private let move: NSSegmentedControl
    /// The rule that makes the row as wide as the stack. Held because a
    /// reorder takes the row out of the stack, which invalidates it.
    var widthMatch: NSLayoutConstraint?
    /// Which of the two symbols the pause button is showing. Nil until the
    /// first update, so that update always sets the image.
    private var showingPaused: Bool?

    init(jobID: UUID, target: AnyObject,
         pauseAction: Selector, cancelAction: Selector,
         retryAction: Selector, reorderAction: Selector) {
        pause = NSButton(
            image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause") ?? NSImage(),
            target: target, action: pauseAction
        )
        stop = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") ?? NSImage(),
            target: target, action: cancelAction
        )
        retry = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry failed") ?? NSImage(),
            target: target, action: retryAction
        )
        move = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up") ?? NSImage(),
                NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down") ?? NSImage(),
            ],
            trackingMode: .momentary, target: target, action: reorderAction
        )
        super.init(frame: .zero)
        build(jobID: jobID)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(jobID: UUID) {
        translatesAutoresizingMaskIntoConstraints = false

        title.font = Theme.rowName
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        status.font = Theme.rowNumeric
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        // NSProgressIndicator starts out indeterminate, and the first update
        // only reacts to a change, so the known state is written down here.
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        let identifier = NSUserInterfaceItemIdentifier(jobID.uuidString)
        for button in [pause, stop, retry] {
            button.identifier = identifier
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        move.identifier = identifier
        move.segmentStyle = .smallSquare
        move.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, bar, status, pause, stop, retry, move] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 62),

            retry.trailingAnchor.constraint(equalTo: pause.leadingAnchor, constant: -2),
            retry.centerYAnchor.constraint(equalTo: centerYAnchor),
            retry.widthAnchor.constraint(equalToConstant: 24),

            move.trailingAnchor.constraint(equalTo: retry.leadingAnchor, constant: -2),
            move.centerYAnchor.constraint(equalTo: centerYAnchor),

            stop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stop.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 24),

            pause.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -2),
            pause.centerYAnchor.constraint(equalTo: centerYAnchor),
            pause.widthAnchor.constraint(equalToConstant: 24),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: move.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            bar.heightAnchor.constraint(equalToConstant: 6),

            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
        ])
    }

    /// Puts the job's current numbers into the views that are already there.
    func update(with job: TransferJob, formatter: ByteCountFormatter) {
        let state = job.state
        title.stringValue = job.title
        status.stringValue = job.statusLine(formatter: formatter)
        status.textColor = state == .failed ? Theme.danger : .secondaryLabelColor

        let indeterminate = job.totalBytes == 0 && state == .running
        if bar.isIndeterminate != indeterminate {
            bar.isIndeterminate = indeterminate
            if indeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        }
        if !indeterminate { bar.doubleValue = job.fractionComplete }

        // The image carries the button's accessibility label, so a paused job
        // reads as Resume to VoiceOver as well as looking like a play button.
        // It is replaced only when the job changes state: a new image on every
        // tick tells an assistive client the button has changed twice a second
        // for no reason.
        let paused = state == .paused
        if showingPaused != paused {
            showingPaused = paused
            pause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                  accessibilityDescription: paused ? "Resume" : "Pause") ?? NSImage()
        }
        pause.isEnabled = job.isActive
        stop.isEnabled = job.isActive

        let failures = job.failures.count
        retry.isHidden = failures == 0 || job.isActive
        retry.toolTip = failures == 1
            ? "Try the 1 file that failed again"
            : "Try the \(failures) files that failed again"

        // Only a waiting job can be reordered; one already moving bytes cannot
        // be un-started by putting it lower in a list.
        move.isHidden = state != .waiting
    }
}
