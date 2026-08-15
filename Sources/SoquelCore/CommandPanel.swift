import AppKit

/// A command line attached to the folder in front of you.
final class CommandPanelController: NSWindowController {
    static let shared: CommandPanelController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.setFrameAutosaveName("SoquelCommand")
        let controller = CommandPanelController(window: window)
        window.delegate = controller
        controller.build()
        return controller
    }()

    /// Set by the window and kept current as the focused pane navigates.
    var directory: URL? {
        didSet { updateTitle() }
    }

    private let runner = CommandRunner()
    private var output: NSTextView!
    private var input: NSTextField!
    private var footer: NSTextField!
    private var runButton: NSButton!
    private var history: [String] = []
    private var historyIndex: Int?

    private func build() {
        output = NSTextView()
        output.isEditable = false
        output.isRichText = false
        output.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        output.textContainerInset = NSSize(width: 6, height: 6)
        output.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        input = NSTextField()
        input.placeholderString = "git status"
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.target = self
        input.action = #selector(runTyped)
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        runButton = NSButton(title: "Run", target: self, action: #selector(runTyped))
        runButton.keyEquivalent = "\r"
        runButton.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString:
            "Runs one command and shows what it prints. Not a terminal — ⌃⌘T opens that.")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        [scroll, input, runButton, footer].forEach { content.addSubview($0!) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -10),

            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            input.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            runButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            runButton.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func show(in directory: URL?, over parent: NSWindow?) {
        self.directory = directory
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
    }

    private func updateTitle() {
        window?.title = directory.map { "Run in \($0.lastPathComponent)" } ?? "Run"
    }

    private func append(_ text: String) {
        output.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        output.scrollToEndOfDocument(nil)
    }

    @objc private func runTyped() {
        // A running command has to be stopped rather than stacked on top of.
        if runner.isRunning {
            runner.cancel()
            return
        }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let directory else { return }

        history.append(command)
        historyIndex = nil
        input.stringValue = ""

        append("\n$ \(command)\n")
        footer.stringValue = "Running…"
        runButton.title = "Stop"

        runner.run(command, in: directory) { [weak self] event in
            guard let self else { return }
            switch event {
            case .output(let text):
                self.append(text)
            case .finished(let status):
                self.footer.stringValue = CommandRunner.exitSummary(status: status)
                self.runButton.title = "Run"
            }
        }
    }

    override func close() {
        runner.cancel()
        super.close()
    }
}

extension CommandPanelController: NSWindowDelegate {
    /// The red close button goes through NSWindow.performClose, which never
    /// calls NSWindowController.close(), so the delegate callback is the only
    /// place that hears about it. Without it the command keeps running with
    /// its output streaming into a hidden view.
    func windowWillClose(_ notification: Notification) {
        runner.cancel()
    }
}

extension CommandPanelController: NSTextFieldDelegate {
    /// Up and down walk back through what has been run, the way a shell does.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !history.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            historyIndex = CommandPanelController.previousIndex(historyIndex, count: history.count)
        case #selector(NSResponder.moveDown(_:)):
            historyIndex = CommandPanelController.nextIndex(historyIndex, count: history.count)
        default:
            return false
        }
        input.stringValue = historyIndex.map { history[$0] } ?? ""
        return true
    }

    /// One older. From nothing typed, the most recent.
    static func previousIndex(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return max(0, current - 1)
    }

    /// One newer. Past the newest is an empty field, not a wrap to the oldest.
    static func nextIndex(_ current: Int?, count: Int) -> Int? {
        guard let current, count > 0 else { return nil }
        return current + 1 >= count ? nil : current + 1
    }
}
