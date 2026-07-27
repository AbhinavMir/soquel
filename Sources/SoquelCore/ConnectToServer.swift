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
            self?.panel = nil
            self?.owner = nil
        }
        panel.makeFirstResponder(field)
    }

    private func build(in panel: NSPanel) {
        let prompt = NSTextField(labelWithString: "Server address")
        prompt.font = Theme.sectionLabel
        prompt.textColor = .secondaryLabelColor
        prompt.translatesAutoresizingMaskIntoConstraints = false

        field = NSTextField()
        field.placeholderString = "smb://server/share"
        field.font = Theme.path
        field.target = self
        field.action = #selector(connect)
        field.translatesAutoresizingMaskIntoConstraints = false

        recentList = NSPopUpButton()
        recentList.target = self
        recentList.action = #selector(pickRecent)
        recentList.translatesAutoresizingMaskIntoConstraints = false
        reloadRecents()

        // Naming the protocols is the difference between "it does not work"
        // and "that one needs macFUSE".
        let supported = NSTextField(labelWithString:
            "smb:// · afp:// · nfs:// · https:// and http:// for WebDAV · ftp:// (read-only). "
            + "sftp:// needs macFUSE and sshfs.")
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

    @objc private func connect() {
        status.stringValue = ""

        switch RemoteLocations.parse(field.stringValue) {
        case .failure(let error):
            status.stringValue = error.localizedDescription
            NSSound.beep()

        case .success(let address):
            if let problem = RemoteLocations.check(address) {
                status.stringValue = problem.localizedDescription
                NSSound.beep()
                return
            }
            connectButton.isEnabled = false
            spinner.startAnimation(nil)
            status.textColor = .secondaryLabelColor
            status.stringValue = "Connecting to \(address.host)…"

            RemoteLocations.mount(address) { [weak self] result in
                guard let self else { return }
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
