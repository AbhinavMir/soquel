import AppKit

/// Finding what an application left around the system.
///
/// Dragging a .app to the Trash leaves its preferences, caches, containers and
/// support folders behind. This finds them and shows them; it does not decide
/// for you.
enum Uninstall {
    struct Leftover {
        let url: URL
        let kind: String
        let bytes: Int64
        /// Matched on the bundle identifier rather than a guess at the name.
        let confidence: Confidence
    }

    /// How the file was matched, because that decides how much to trust it.
    enum Confidence: String, Comparable {
        /// The path contains the exact bundle identifier. Very unlikely to be
        /// anything else.
        case exact
        /// The path contains the application's name. A folder called "Notes"
        /// might belong to Apple's Notes or to something else entirely.
        case byName

        static func < (a: Confidence, b: Confidence) -> Bool {
            a == .exact && b == .byName
        }
    }

    /// The directories an application scatters things through.
    static func searchRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(URL, String)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            (library.appendingPathComponent("Application Support"), "Support files"),
            (library.appendingPathComponent("Caches"), "Cache"),
            (library.appendingPathComponent("Preferences"), "Preferences"),
            (library.appendingPathComponent("Containers"), "Container"),
            (library.appendingPathComponent("Group Containers"), "Group container"),
            (library.appendingPathComponent("Saved Application State"), "Saved state"),
            (library.appendingPathComponent("Logs"), "Logs"),
            (library.appendingPathComponent("HTTPStorages"), "Web storage"),
            (library.appendingPathComponent("WebKit"), "Web storage"),
            (library.appendingPathComponent("LaunchAgents"), "Launch agent"),
            (library.appendingPathComponent("Cookies"), "Cookies"),
        ]
    }

    static func bundleIdentifier(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// The app's name without ".app", used as the weaker of the two matches.
    static func displayName(of app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }

    /// Whether a filename belongs to this application.
    ///
    /// The identifier match is a path-component match, not a substring one:
    /// `com.acme.Thing` must not drag in `com.acme.ThingElse`. The name match
    /// requires a word boundary for the same reason — "Mail" should not claim
    /// "MailChimp Designer".
    static func matches(_ filename: String, identifier: String?, name: String) -> Confidence? {
        // Both the whole name and the name with a trailing extension removed.
        // A Caches folder is called `com.acme.Thing` with no extension at all,
        // and stripping ".Thing" from it as though it were one is how the most
        // common case gets missed.
        let candidates = [filename, (filename as NSString).deletingPathExtension]

        if let identifier, !identifier.isEmpty {
            for candidate in candidates where candidate == identifier
                || candidate.hasPrefix(identifier + ".") {
                return .exact
            }
        }
        for candidate in candidates where candidate == name
            || candidate.hasPrefix(name + " ") || candidate.hasPrefix(name + "-") {
            return .byName
        }
        return nil
    }

    /// Scans the usual places. Only the top level of each is read: something
    /// two levels down inside another application's folder is that
    /// application's business.
    static func leftovers(
        for app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Leftover] {
        let identifier = bundleIdentifier(of: app)
        let name = displayName(of: app)
        var found: [Leftover] = []

        for (root, kind) in searchRoots(home: home) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
            ) else { continue }

            for entry in entries {
                guard let confidence = matches(
                    entry.lastPathComponent, identifier: identifier, name: name
                ) else { continue }
                found.append(Leftover(
                    url: entry, kind: kind, bytes: size(of: entry), confidence: confidence
                ))
            }
        }
        // Exact matches first, then biggest, so what is worth reviewing is at
        // the top and the guesses are at the bottom.
        return found.sorted {
            $0.confidence == $1.confidence ? $0.bytes > $1.bytes : $0.confidence < $1.confidence
        }
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }

        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            guard let child = try? child.resourceValues(forKeys: Set(keys)),
                  child.isDirectory != true, child.isSymbolicLink != true
            else { continue }
            total += Int64(child.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func summary(_ leftovers: [Leftover]) -> String {
        guard !leftovers.isEmpty else { return "Nothing left behind" }
        let bytes = leftovers.reduce(0) { $0 + $1.bytes }
        let n = leftovers.count == 1 ? "1 item" : "\(leftovers.count) items"
        return "\(n) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// The review window.
final class UninstallPanelController: NSWindowController {
    private var app: URL!
    private var leftovers: [Uninstall.Leftover] = []
    private var ticked: Set<URL> = []
    private var table: NSTableView!
    private var footer: NSTextField!
    private var trashButton: NSButton!
    private var includeApp = true

    var onFinished: (() -> Void)?

    static func show(_ app: URL, over parent: NSWindow?, onFinished: (() -> Void)? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Uninstall \(Uninstall.displayName(of: app))"
        let controller = UninstallPanelController(window: window)
        controller.app = app
        controller.onFinished = onFinished
        controller.build()
        controller.load()
        if let parent {
            window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - window.frame.width / 2,
                y: parent.frame.midY - window.frame.height / 2
            ))
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        table = NSTableView()
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString:
            "Matches on the bundle identifier are marked exact. The rest match the "
            + "application's name and may belong to something else — check before ticking.")
        note.font = Theme.rowSecondary
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.translatesAutoresizingMaskIntoConstraints = false

        footer = NSTextField(labelWithString: "Scanning…")
        footer.font = Theme.status
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let tickExact = NSButton(title: "Tick Exact Matches", target: self, action: #selector(tickExact))
        trashButton = NSButton(title: "Move to Trash", target: self, action: #selector(trashTicked))
        trashButton.isEnabled = false
        for button in [tickExact, trashButton!] { button.translatesAutoresizingMaskIntoConstraints = false }

        let content = window!.contentView!
        [note, scroll, footer, tickExact, trashButton].forEach { content.addSubview($0!) }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: tickExact.leadingAnchor, constant: -10),

            tickExact.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            tickExact.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            trashButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func load() {
        let target = app!
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Uninstall.leftovers(for: target)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.leftovers = found
                self.table.reloadData()
                self.updateFooter()
            }
        }
    }

    private func updateFooter() {
        let count = ticked.count + (includeApp ? 1 : 0)
        footer.stringValue = "\(Uninstall.summary(leftovers)) · \(count) ticked"
        trashButton.isEnabled = count > 0
    }

    @objc private func tickExact() {
        ticked = Set(leftovers.filter { $0.confidence == .exact }.map(\.url))
        table.reloadData()
        updateFooter()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard let url = sender.cell?.representedObject as? URL else { return }
        if url == app {
            includeApp = sender.state == .on
        } else if sender.state == .on {
            ticked.insert(url)
        } else {
            ticked.remove(url)
        }
        updateFooter()
    }

    @objc private func trashTicked() {
        var urls = leftovers.map(\.url).filter { ticked.contains($0) }
        if includeApp { urls.append(app) }
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Move \(urls.count) item(s) to the Trash?"
        alert.informativeText = "They go to the Trash, so ⌘Z and the Trash itself can both bring them back."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        OperationEngine.shared.trash(urls) { [weak self] result in
            guard let self else { return }
            UndoStack.shared.pushTrash(result.trashedPairs)
            self.onFinished?()
            if result.failures.isEmpty {
                self.close()
            } else {
                self.footer.stringValue = "\(result.failures.count) item(s) could not be moved"
                self.load()
            }
        }
    }
}

extension UninstallPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { leftovers.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()

        let title: String
        let url: URL
        let state: NSControl.StateValue
        if row == 0 {
            url = app
            title = "\(app.lastPathComponent) — the application itself"
            state = includeApp ? .on : .off
        } else {
            let leftover = leftovers[row - 1]
            url = leftover.url
            let size = ByteCountFormatter.string(fromByteCount: leftover.bytes, countStyle: .file)
            let mark = leftover.confidence == .exact ? "exact" : "name only"
            title = "\(leftover.kind) · \(size) · \(mark)\n\(leftover.url.path)"
            state = ticked.contains(url) ? .on : .off
        }

        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleRow(_:)))
        box.cell?.representedObject = url
        box.state = state
        box.font = Theme.rowSecondary
        box.lineBreakMode = .byTruncatingMiddle
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            box.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
