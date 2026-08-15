import AppKit

/// The Connect to Server sheet.
///
/// One field and a list of what you connected to before. Credentials are not
/// asked for here: the system's own authentication sheet handles them, backed
/// by the keychain, so no password passes through this application.
final class ConnectToServerController: NSObject {
    private var panel: NSPanel?
    private weak var owner: MainWindowController?

    private var field: NSTextField!
    private var recentList: NSPopUpButton!
    private var status: NSTextField!
    private var connectButton: NSButton!
    private var spinner: NSProgressIndicator!

    /// Called with the mount point once a server is mounted.
    var onMounted: ((URL) -> Void)?

    func present(for controller: MainWindowController) {
        guard let host = controller.window, panel == nil else { return }
        owner = controller

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Connect to Server"
        build(in: panel)
        self.panel = panel

        host.beginSheet(panel) { [weak self] _ in
            guard let self else { return }
            self.panel = nil
            self.owner = nil
            // Cancel can close the sheet while NetFS still blocks on a mount.
            // If the flag survived into the next presentation, Connect in the
            // reopened sheet would be refused, silently, until the stale call
            // returned. The bump makes that call's completion obsolete, so
            // its result cannot land in a sheet it does not belong to.
            self.isMounting = false
            self.attempt += 1
        }
        panel.makeFirstResponder(field)
    }

    private func build(in panel: NSPanel) {
        let prompt = NSTextField(labelWithString: "Server address")
        prompt.font = Theme.sectionLabel
        prompt.textColor = .secondaryLabelColor
        prompt.translatesAutoresizingMaskIntoConstraints = false

        field = NSTextField()
        field.placeholderString = "me@server.com"
        field.font = Theme.path
        field.target = self
        field.action = #selector(connect)
        field.translatesAutoresizingMaskIntoConstraints = false

        recentList = NSPopUpButton()
        recentList.target = self
        recentList.action = #selector(pickRecent)
        recentList.translatesAutoresizingMaskIntoConstraints = false
        reloadRecents()

        // One line, not a protocol table. Someone who needs smb:// already
        // knows to type it; someone connecting to a server they ssh into
        // should not have to learn a scheme first.
        let supported = NSTextField(labelWithString:
            "Or smb:// · afp:// · nfs:// · https:// for WebDAV · ftp://")
        supported.font = Theme.rowSecondary
        supported.textColor = .tertiaryLabelColor
        supported.lineBreakMode = .byWordWrapping
        supported.maximumNumberOfLines = 2
        supported.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = Theme.danger
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 2
        status.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: "Connect", target: self, action: #selector(connect))
        connectButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [spinner, cancel, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for view in [prompt, field, recentList, supported, status, buttons] as [NSView] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            prompt.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),

            field.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 5),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: recentList.leadingAnchor, constant: -8),

            recentList.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            recentList.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            recentList.widthAnchor.constraint(equalToConstant: 110),

            supported.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            supported.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            supported.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            status.topAnchor.constraint(equalTo: supported.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: status.bottomAnchor, constant: 10),
        ])
        panel.contentView = root
    }

    private func reloadRecents() {
        recentList.removeAllItems()
        let recents = RemoteLocations.recents
        recentList.addItem(withTitle: recents.isEmpty ? "No recents" : "Recent")
        recentList.isEnabled = !recents.isEmpty
        for address in recents {
            recentList.addItem(withTitle: address)
        }
        if !recents.isEmpty {
            recentList.menu?.addItem(.separator())
            recentList.addItem(withTitle: "Clear Recents")
        }
    }

    @objc private func pickRecent(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, sender.indexOfSelectedItem > 0 else { return }
        if title == "Clear Recents" {
            RemoteLocations.forgetRecents()
            reloadRecents()
            return
        }
        field.stringValue = title
        recentList.selectItem(at: 0)
    }

    @objc private func close() {
        guard let panel, let owner = owner?.window else { return }
        owner.endSheet(panel)
    }

    /// Fills in the scheme nobody should have to type.
    ///
    /// An address with an `@` in it and no scheme is what a person types when
    /// they mean the server they ssh into, so it is read as sftp. Anything
    /// else is left alone and fails with a message naming the schemes.
    static func completing(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        guard trimmed.contains("@") else { return trimmed }
        return "sftp://" + trimmed
    }

    /// SFTP needs a username; the browser has nobody to log in as without one.
    /// The address bar accepts `sftp://host` all the same, so the logged-in
    /// account stands in, which is what ssh itself does.
    private func sftpLocation(from address: RemoteLocations.Address) -> SFTPSession.Location? {
        let user = address.user?.isEmpty == false ? address.user! : NSUserName()
        let path = address.path.isEmpty ? "." : address.path
        return SFTPSession.Location(
            user: user, host: address.host, port: address.port, path: path
        )
    }

    /// Return in the address field fires connect() too, and the field stays
    /// first responder while a mount runs. Without this, a second Return
    /// starts a second mount of the same URL against the first.
    private var isMounting = false

    /// Counts presentations of the sheet. A mount completion compares its
    /// captured value against this, so a mount that outlived a cancelled
    /// sheet cannot write an old result into the sheet that replaced it.
    private var attempt = 0

    @objc private func connect() {
        guard !isMounting else { return }
        status.stringValue = ""

        switch RemoteLocations.parse(Self.completing(field.stringValue)) {
        case .failure(let error):
            status.stringValue = error.localizedDescription
            NSSound.beep()

        case .success(let address):
            // Before check(), not after. check() answers "can this be mounted",
            // and the answer for SFTP is no and always will be — it opens in a
            // browser window instead. Asking first meant the refusal was
            // printed and the browser never ran.
            if address.scheme == .sftp, let location = sftpLocation(from: address) {
                // The browser records the address in recents once ssh accepts
                // the connection — the same verified-only contract the mount
                // paths keep. Recording here, before any connection, put
                // typos and dead hosts at the top of the recents list.
                let host = panel?.sheetParent
                close()
                SFTPBrowserController.open(location, remembering: address, over: host)
                return
            }

            if let problem = RemoteLocations.check(address) {
                status.stringValue = problem.localizedDescription
                NSSound.beep()
                return
            }

            isMounting = true
            connectButton.isEnabled = false
            spinner.startAnimation(nil)
            status.textColor = .secondaryLabelColor
            status.stringValue = "Connecting to \(address.host)…"

            let attempt = self.attempt
            RemoteLocations.mount(address) { [weak self] result in
                guard let self, attempt == self.attempt else { return }
                self.isMounting = false
                self.spinner.stopAnimation(nil)
                self.connectButton.isEnabled = true

                switch result {
                case .success(let mounted):
                    self.reloadRecents()
                    self.onMounted?(mounted.mountPoint)
                    self.close()
                case .failure(let error):
                    self.status.textColor = Theme.danger
                    self.status.stringValue = error.localizedDescription
                    NSSound.beep()
                }
            }
        }
    }
}
