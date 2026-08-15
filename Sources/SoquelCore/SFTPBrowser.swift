import AppKit

/// Browsing a server over SFTP, in a window, with nothing installed.
///
/// Not a mount: no other application can see these files, and that is the
/// honest trade for needing no kernel extension and no File Provider. Opening
/// a file fetches it to a temporary folder first, which is what "download on
/// open" means everywhere else too.
final class SFTPBrowserController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var table: NSTableView!
    private var pathLabel: NSTextField!
    private var status: NSTextField!
    private var session: SFTPSession?
    /// The typed address, held until the connection succeeds so it can be
    /// recorded in recents at that moment and not before.
    private var address: RemoteLocations.Address?

    private var entries: [SFTPSession.Entry] = []
    private var path = "."
    /// Where the user has been, so Up has somewhere to go.
    private var history: [String] = []

    /// Every open browser. A single slot meant opening a second window
    /// released the first while it was still on screen.
    private static var live: Set<SFTPBrowserController> = []

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Opens a window on `location`, asking for a password only if the server
    /// wants one. A host already in the SSH agent connects without a prompt.
    /// `address` is what the user typed; it enters the recents list only
    /// after the server accepts the connection, like every mounted scheme.
    static func open(
        _ location: SFTPSession.Location,
        remembering address: RemoteLocations.Address,
        over host: NSWindow?
    ) {
        let controller = SFTPBrowserController()
        live.insert(controller)
        controller.begin(location, remembering: address, over: host)
    }

    private func begin(
        _ location: SFTPSession.Location,
        remembering address: RemoteLocations.Address,
        over host: NSWindow?
    ) {
        let session = SFTPSession(location: location)
        self.session = session
        self.address = address
        self.path = location.path

        build(title: "\(location.user)@\(location.host)")
        setStatus("Connecting to \(location.host)…", isError: false)

        // A password is only collected once the server has refused everything
        // else, so a key-based host never sees the prompt.
        connect(session: session, password: nil) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .connected:
                self.didConnect()
            case .failed:
                // The error is already on the status line. A listing now
                // would run over a connection that was never made and
                // overwrite the one message that says why.
                break
            case .needsPassword:
                // The window is still being presented at this point. Running a
                // modal on top of a window mid-animation is what put an
                // _NSWindowTransformAnimation in an autorelease pool that
                // outlived the window it was animating.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.promptAndConnect(session: session, location: location)
                }
            }
        }
    }

    private func promptAndConnect(session: SFTPSession, location: SFTPSession.Location) {
        switch askForPassword(user: location.user, host: location.host) {
        case .cancelled:
            close()
        case .blank:
            // Not a cancel. Closing the window here was the crash: it tore the
            // window down from inside the alert's own dismissal.
            setStatus("No password entered.", isError: true)
        case .entered(let password):
            setStatus("Connecting to \(location.host)…", isError: false)
            connect(session: session, password: password) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .connected:
                    self.didConnect()
                case .needsPassword:
                    self.setStatus("That username or password was refused.", isError: true)
                case .failed:
                    // The status line already carries the error; there is no
                    // connection to list over.
                    break
                }
            }
        }
    }

    /// The mount flows record an address only after a verified mount. The
    /// browser keeps that contract: the address enters the recents list
    /// here, once ssh has accepted the connection, so a typo or a dead host
    /// never takes one of the ten slots from an address that works.
    private func didConnect() {
        if let address {
            RemoteLocations.remember(address)
        }
        load(path)
    }

    /// How an attempt at the master connection ended. Success and a hard
    /// failure both used to read as "not failed", which sent a listing down
    /// a connection that was never made.
    private enum ConnectOutcome {
        case connected
        /// The server refused the credentials; a password prompt can help.
        case needsPassword
        /// Anything else. The error has already been put on the status line.
        case failed
    }

    /// The connection is made off the main queue: a server that is not
    /// answering would otherwise freeze the application until it timed out.
    private func connect(
        session: SFTPSession, password: String?, then finish: @escaping (ConnectOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try session.connect(password: password) } catch { failure = error }
            DispatchQueue.main.async {
                if let failure {
                    Log.error(.remote, "SFTP connect failed: \(failure.localizedDescription)")
                    // Anything that is not a rejected password is worth showing
                    // as it stands; asking for a password again would not help.
                    if case SFTPSession.Failure.authenticationFailed = failure {
                        finish(.needsPassword)
                    } else {
                        self.setStatus(failure.localizedDescription, isError: true)
                        finish(.failed)
                    }
                    return
                }
                finish(.connected)
            }
        }
    }

    /// Cancel and an empty box are different answers. Treating both as nil
    /// closed the window from inside the alert's own teardown, which
    /// deallocated it while AppKit was still animating it — a segfault in
    /// `_NSWindowTransformAnimation dealloc`.
    enum PasswordAnswer {
        case entered(String)
        case blank
        case cancelled
    }

    private func askForPassword(user: String, host: String) -> PasswordAnswer {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let alert = NSAlert()
        alert.messageText = "Password for \(user)@\(host)"
        alert.informativeText = "The password is sent to ssh over a pipe and is not stored."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
        return field.stringValue.isEmpty ? .blank : .entered(field.stringValue)
    }

    // MARK: - Listing

    /// Each request takes a number so that only the latest one may land:
    /// two listings can be in flight at once, and a slow folder's rows must
    /// not arrive under a label that already names a different one.
    private var loadGeneration = 0

    /// The navigation in flight, if any: where it goes, and what the history
    /// will be once its listing arrives. goUp starts from this instead of
    /// the committed path, so each press climbs one more level even while
    /// the server has not answered the previous press.
    private struct PendingNavigation {
        var path: String
        var history: [String]
    }
    private var pending: PendingNavigation?

    /// Reads `path`, and only makes it the current folder once the listing
    /// arrives. Committing the path up front left the table showing one
    /// folder while every double-click resolved names against another.
    /// `historyOnArrival` is installed at that same moment, and only then:
    /// history changes are part of the navigation, and a folder that refuses
    /// to list must leave the history it would have consumed intact.
    private func load(_ path: String, historyOnArrival: [String]? = nil) {
        guard let session else { return }
        loadGeneration += 1
        let generation = loadGeneration
        pending = PendingNavigation(path: path, history: historyOnArrival ?? history)
        setStatus("Reading…", isError: false)

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [SFTPSession.Entry] = []
            var failure: Error?
            do { found = try session.list(path) } catch { failure = error }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                if let failure {
                    // The navigation did not happen. Drop it, so the next Up
                    // starts again from the folder still on screen.
                    self.pending = nil
                    self.setStatus(failure.localizedDescription, isError: true)
                    return
                }
                self.path = path
                if let historyOnArrival { self.history = historyOnArrival }
                self.pending = nil
                self.pathLabel.stringValue = path == "." ? "~" : path
                // Folders first, then by name — the same order the rest of the
                // application uses when it is not asked for something else.
                self.entries = found.sorted {
                    $0.isDirectory != $1.isDirectory
                        ? $0.isDirectory
                        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.table.reloadData()
                let count = self.entries.count
                self.setStatus("\(count) item\(count == 1 ? "" : "s")", isError: false)
            }
        }
    }

    private func child(_ name: String) -> String {
        path == "." ? name : (path as NSString).appendingPathComponent(name)
    }

    @objc private func rowDoubleClicked() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        if entry.isDirectory {
            // History records only navigations that completed; a refused
            // folder never happened, so Up must not lead back to it. The
            // rows on screen belong to the committed folder, so the entry
            // pushed is the committed path, not any navigation in flight.
            let target = child(entry.name)
            load(target, historyOnArrival: target == path ? history : history + [path])
        } else {
            openFile(entry)
        }
    }

    @objc private func goUp() {
        // Start from the navigation in flight when there is one: two quick
        // presses must climb two levels, not compute the same parent twice.
        let fromPath = pending?.path ?? path
        let fromHistory = pending?.history ?? history
        if let previous = fromHistory.last {
            // The entry is not popped here. It leaves the history only when
            // the listing arrives; a folder that refuses to list would
            // otherwise consume the entry without going anywhere.
            load(previous, historyOnArrival: Array(fromHistory.dropLast()))
            return
        }
        guard fromPath != ".", fromPath != "/" else { return }
        let parent = (fromPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "." : parent, historyOnArrival: fromHistory)
    }

    /// Fetches the file to a temporary folder and hands it to whatever opens
    /// that kind. Edits made there do not go back to the server — this browses
    /// and downloads, it does not sync.
    private func openFile(_ entry: SFTPSession.Entry) {
        guard let session else { return }
        let remote = child(entry.name)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soquel-SFTP", isDirectory: true)
        let local = folder.appendingPathComponent(entry.name)
        setStatus("Downloading \(entry.name)…", isError: false)

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true
                )
                try session.download(remote, to: local)
            } catch { failure = error }
            DispatchQueue.main.async {
                if let failure {
                    self.setStatus(failure.localizedDescription, isError: true)
                    return
                }
                self.setStatus("Downloaded to \(local.path)", isError: false)
                NSWorkspace.shared.open(local)
            }
        }
    }

    @objc private func saveHere() {
        guard let session, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Download Here"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url,
                  self.entries.indices.contains(self.table.selectedRow)
            else { return }
            let entry = self.entries[self.table.selectedRow]
            let remote = self.child(entry.name)
            let local = Self.uniqueLocalURL(for: entry.name, in: destination)
            self.setStatus("Downloading \(entry.name)…", isError: false)
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                do { try session.download(remote, to: local) } catch { failure = error }
                DispatchQueue.main.async {
                    self.setStatus(
                        failure?.localizedDescription ?? "Saved \(local.lastPathComponent)",
                        isError: failure != nil
                    )
                }
            }
        }
    }

    /// "name.ext", then "name 2.ext", "name 3.ext" — sftp's get truncates an
    /// existing file without asking, so a taken name is never handed to it.
    static func uniqueLocalURL(for name: String, in directory: URL,
                               fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    // MARK: - The window

    private func build(title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.center()
        // No NSWindowController owns this window, so AppKit's close-time
        // release plus this controller's own strong reference over-released
        // it and closing the window could crash the app.
        window.isReleasedWhenClosed = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 640
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "~")
        pathLabel.font = Theme.rowNumeric
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        let up = NSButton(title: "Up", target: self, action: #selector(goUp))
        up.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Download…", target: self, action: #selector(saveHere))
        let buttons = NSStackView(views: [save])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [up, pathLabel, scroll, status, buttons] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            up.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            up.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            pathLabel.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: up.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func setStatus(_ text: String, isError: Bool) {
        status.stringValue = text
        status.textColor = isError ? Theme.danger : .secondaryLabelColor
    }

    /// Closing a window from inside a modal's teardown destroys it while
    /// AppKit is still animating it. The next runloop turn is safe.
    private func close() {
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    // MARK: - Rows

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]

        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: entry.isDirectory ? "folder" : (entry.isSymlink ? "arrow.turn.up.right" : "doc"),
            accessibilityDescription: nil
        )
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: entry.name)
        name.font = Theme.rowName
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        // A folder's size is whatever the server says the directory entry
        // weighs, which is not what is inside it, so it is not shown.
        let detail = NSTextField(labelWithString: entry.isDirectory
            ? "—" : Self.byteFormatter.string(fromByteCount: entry.size))
        detail.font = Theme.rowNumeric
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, name, detail] as [NSView] { cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.widthAnchor.constraint(equalToConstant: 90),
        ])
        return cell
    }
}

extension SFTPBrowserController: NSWindowDelegate {
    /// The master connection is the app's, not ssh's to keep. Leaving it open
    /// would hold a socket in /tmp and a process on the server.
    func windowWillClose(_ notification: Notification) {
        let session = self.session
        self.session = nil
        DispatchQueue.global(qos: .utility).async { session?.disconnect() }
        // Not during the notification: releasing the last reference here
        // deallocates this object, and its window, while AppKit is still
        // inside the close it is telling us about.
        DispatchQueue.main.async { SFTPBrowserController.live.remove(self) }
    }
}
