import AppKit

/// Settings → Updates.
final class UpdateSettingsView: NSView {
    private var toggle: NSButton!
    private var status: NSTextField!
    private var checkButton: NSButton!
    private var recallToggle: NSButton!
    private var recallStatus: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let title = NSTextField(labelWithString:
            "There is no account and no telemetry. Nothing about this machine, or about what "
            + "is on it, is sent by either of the two checks below.")
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

        recallToggle = NSButton(
            checkboxWithTitle: "Warn me if this build is known to be faulty",
            target: self, action: #selector(recallChanged)
        )
        recallToggle.state = BuildAdvisory.isEnabled ? .on : .off
        recallToggle.translatesAutoresizingMaskIntoConstraints = false

        let recallDetail = NSTextField(labelWithString:
            "Separate from the check above, and on unless you turn it off. It reads one list of "
            + "withdrawn versions from trysoquel.com and says so if this build is on it. A "
            + "faulty build can lose your files, so this one does not wait to be asked. When it "
            + "fires you get a button to install the fix and a button to go back to the last "
            + "good version; both check the signature before replacing anything.")
        recallDetail.font = Theme.rowSecondary
        recallDetail.textColor = .secondaryLabelColor
        recallDetail.lineBreakMode = .byWordWrapping
        recallDetail.maximumNumberOfLines = 6
        recallDetail.translatesAutoresizingMaskIntoConstraints = false

        let recallButton = NSButton(title: "Check This Build",
                                    target: self, action: #selector(checkBuild))
        recallButton.translatesAutoresizingMaskIntoConstraints = false

        recallStatus = NSTextField(labelWithString: "")
        recallStatus.font = Theme.status
        recallStatus.textColor = .secondaryLabelColor
        recallStatus.lineBreakMode = .byTruncatingTail
        recallStatus.translatesAutoresizingMaskIntoConstraints = false

        let version = NSTextField(labelWithString: "This build is \(UpdateCheck.currentVersion).")
        version.font = Theme.status
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false

        [title, toggle, detail, checkButton, status,
         recallToggle, recallDetail, recallButton, recallStatus, version].forEach(addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            toggle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            detail.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            checkButton.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            checkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            status.centerYAnchor.constraint(equalTo: checkButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            recallToggle.topAnchor.constraint(equalTo: checkButton.bottomAnchor, constant: 22),
            recallToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            recallDetail.topAnchor.constraint(equalTo: recallToggle.bottomAnchor, constant: 6),
            recallDetail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            recallDetail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            recallButton.topAnchor.constraint(equalTo: recallDetail.bottomAnchor, constant: 14),
            recallButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            recallStatus.centerYAnchor.constraint(equalTo: recallButton.centerYAnchor),
            recallStatus.leadingAnchor.constraint(equalTo: recallButton.trailingAnchor, constant: 10),
            recallStatus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            // Without a relation to the content above it the pane's height
            // is ambiguous, and the label settled above the pane's own top.
            version.topAnchor.constraint(equalTo: recallButton.bottomAnchor, constant: 20),
            version.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
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

    @objc private func recallChanged() {
        BuildAdvisory.isEnabled = recallToggle.state == .on
        recallStatus.stringValue = BuildAdvisory.isEnabled ? "" : "Off. You will not be warned."
    }

    /// Asks the recall list about this exact build, and says so either way —
    /// "nothing wrong with it" is the answer people press this for.
    @objc private func checkBuild() {
        recallStatus.stringValue = "Asking trysoquel.com…"
        BuildAdvisory.fetch { [weak self] advisory in
            guard let self else { return }
            guard let advisory else {
                self.recallStatus.stringValue =
                    "\(BuildAdvisory.currentVersion) is not on the list."
                return
            }
            self.recallStatus.stringValue = advisory.summary
            AdvisoryPanel.show(advisory)
        }
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
