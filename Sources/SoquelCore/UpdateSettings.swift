import AppKit

/// Settings → Updates.
final class UpdateSettingsView: NSView {
    private var toggle: NSButton!
    private var status: NSTextField!
    private var checkButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let title = NSTextField(labelWithString:
            "Soquel does not contact anything unless you turn this on. There is no account, "
            + "no telemetry, and nothing about this machine is sent either way.")
        title.font = Theme.rowSecondary
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.translatesAutoresizingMaskIntoConstraints = false

        toggle = NSButton(
            checkboxWithTitle: "Tell me when a new version is out",
            target: self, action: #selector(toggleChanged)
        )
        toggle.state = UpdateCheck.isEnabled ? .on : .off
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString:
            "Asks github.com once a day for the latest release tag and compares it with this "
            + "build. Nothing is downloaded or installed — you get told, and the button opens "
            + "the release page.")
        detail.font = Theme.rowSecondary
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.translatesAutoresizingMaskIntoConstraints = false

        checkButton = NSButton(title: "Check Now", target: self, action: #selector(checkNow))
        checkButton.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "")
        status.font = Theme.status
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        let version = NSTextField(labelWithString: "This build is \(UpdateCheck.currentVersion).")
        version.font = Theme.status
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false

        [title, toggle, detail, checkButton, status, version].forEach(addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            toggle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            detail.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            checkButton.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            checkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            status.centerYAnchor.constraint(equalTo: checkButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            version.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            version.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        updateStatus()
    }

    private func updateStatus() {
        checkButton.isEnabled = true
        guard UpdateCheck.isEnabled else {
            status.stringValue = "Off. Nothing is being asked."
            return
        }
        guard let last = UpdateCheck.lastChecked else {
            status.stringValue = "Not checked yet."
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        status.stringValue = "Last checked \(formatter.string(from: last))."
    }

    @objc private func toggleChanged() {
        UpdateCheck.isEnabled = toggle.state == .on
        updateStatus()
    }

    /// Works whether or not the toggle is on: asking once by hand is not the
    /// same as agreeing to be asked every day.
    @objc private func checkNow() {
        checkButton.isEnabled = false
        status.stringValue = "Asking github.com…"
        UpdateCheck.check { [weak self] result in
            guard let self else { return }
            self.checkButton.isEnabled = true
            switch result {
            case .upToDate:
                self.status.stringValue = "\(UpdateCheck.currentVersion) is the latest."
            case .failed(let reason):
                self.status.stringValue = "Could not check: \(reason)"
            case .available(let release):
                self.status.stringValue = "\(release.version) is out."
                UpdateCheck.announce(release)
            }
        }
    }
}
