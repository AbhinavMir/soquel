import AppKit

/// Settings → Default App.
///
/// Every row states what it can actually do. The folder row in particular says
/// that macOS refuses the handler change, because a switch that silently does
/// nothing is worse than a sentence explaining why there is no switch.
final class DefaultAppSettingsView: NSView {
    private var catchToggle: NSButton!
    private var followToggle: NSButton!
    private var volumeToggle: NSButton!
    private var desktopToggle: NSButton!
    private var permissionStatus: NSTextField!
    private var permissionButton: NSButton!
    private var folderFact: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func label(_ text: String, secondary: Bool = false, lines: Int = 4) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if secondary {
            field.font = Theme.rowSecondary
            field.textColor = .secondaryLabelColor
        }
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = lines
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func build() {
        let intro = label(
            "Finder cannot be switched off, and its icon cannot be taken out of the Dock. "
            + "What it can do is stop being the thing that opens. Finder starts, Soquel takes "
            + "over, Finder quits — it does not come back until something asks for it again.",
            secondary: true, lines: 4)

        catchToggle = NSButton(checkboxWithTitle: "Open Soquel when Finder starts",
                               target: self, action: #selector(catchChanged))
        catchToggle.state = FinderTakeover.catchesFinder ? .on : .off
        catchToggle.translatesAutoresizingMaskIntoConstraints = false

        let catchDetail = label(
            "Covers the Dock's Finder icon, Reveal in Finder from other applications, and "
            + "anything else that opens Finder. Needs no permission.",
            secondary: true, lines: 3)

        followToggle = NSButton(checkboxWithTitle: "Open the folder Finder was going to",
                                target: self, action: #selector(followChanged))
        followToggle.state = FinderTakeover.followsFinder ? .on : .off
        followToggle.translatesAutoresizingMaskIntoConstraints = false

        let followDetail = label(
            "Asks Finder what it was told to show, so a revealed file arrives selected rather "
            + "than leaving you in the last folder. This is the part that needs permission to "
            + "control Finder.",
            secondary: true, lines: 3)

        permissionStatus = label("", secondary: true, lines: 2)
        permissionButton = NSButton(title: "Allow Controlling Finder",
                                    target: self, action: #selector(askPermission))
        permissionButton.translatesAutoresizingMaskIntoConstraints = false

        volumeToggle = NSButton(checkboxWithTitle: "Open a disk in Soquel when it is mounted",
                                target: self, action: #selector(volumeChanged))
        volumeToggle.state = FinderTakeover.opensVolumes ? .on : .off
        volumeToggle.translatesAutoresizingMaskIntoConstraints = false

        desktopToggle = NSButton(checkboxWithTitle: "Hide the icons on the desktop",
                                 target: self, action: #selector(desktopChanged))
        desktopToggle.state = FinderTakeover.hidesDesktopIcons ? .on : .off
        desktopToggle.translatesAutoresizingMaskIntoConstraints = false

        let desktopDetail = label(
            "The wallpaper stays; only the icons go. Finder restarts to pick this up.",
            secondary: true, lines: 2)

        folderFact = label("", secondary: true, lines: 3)

        let giveBack = NSButton(title: "Give Everything Back to Finder",
                                target: self, action: #selector(giveBack))
        giveBack.translatesAutoresizingMaskIntoConstraints = false

        let views = [intro, catchToggle!, catchDetail, followToggle!, followDetail,
                     permissionButton!, permissionStatus!, volumeToggle!,
                     desktopToggle!, desktopDetail, folderFact!, giveBack]
        views.forEach(addSubview)

        var constraints: [NSLayoutConstraint] = []
        var previous: NSView?
        for view in views {
            let indented = (view === catchDetail || view === followDetail
                            || view === desktopDetail || view === permissionButton
                            || view === permissionStatus)
            constraints.append(view.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? 34 : 18))
            constraints.append(view.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -18))
            let gap: CGFloat = previous == nil ? 14 : (indented ? 6 : 16)
            constraints.append(view.topAnchor.constraint(
                equalTo: previous?.bottomAnchor ?? topAnchor, constant: gap))
            previous = view
        }
        constraints.append(previous!.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)

        refresh()
    }

    /// Reads the machine rather than what was last written. A pane that shows a
    /// remembered toggle while the system says otherwise is how somebody ends
    /// up believing the application is broken.
    private func refresh() {
        catchToggle.state = FinderTakeover.catchesFinder ? .on : .off
        volumeToggle.state = FinderTakeover.opensVolumes ? .on : .off
        desktopToggle.state = FinderTakeover.hidesDesktopIcons ? .on : .off

        let allowed = FinderTakeover.hasAutomationPermission()
        followToggle.isEnabled = allowed
        followToggle.state = (allowed && FinderTakeover.followsFinder) ? .on : .off
        permissionButton.isHidden = allowed
        permissionStatus.stringValue = allowed
            ? "Soquel may control Finder."
            : "Not allowed yet, so the folder cannot be read."
        permissionStatus.textColor = allowed ? .secondaryLabelColor : Theme.danger

        let handler = FinderTakeover.defaultHandler(for: "public.folder") ?? "none"
        folderFact.stringValue = FinderTakeover.canClaimFolders()
            ? "Double-clicked folders open in Soquel."
            : "Double-clicked folders open in Finder first — macOS refuses to hand the folder "
              + "type to any other application (\(handler)). Catching the launch above is what "
              + "gets you to Soquel instead."
    }

    @objc private func catchChanged() {
        FinderTakeover.catchesFinder = catchToggle.state == .on
        refresh()
    }

    @objc private func followChanged() {
        FinderTakeover.followsFinder = followToggle.state == .on
        refresh()
    }

    @objc private func volumeChanged() {
        FinderTakeover.opensVolumes = volumeToggle.state == .on
        // The change is not instant, so the row is re-read rather than assumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    @objc private func desktopChanged() {
        FinderTakeover.hidesDesktopIcons = desktopToggle.state == .on
        refresh()
    }

    @objc private func askPermission() {
        permissionButton.isEnabled = false
        permissionStatus.stringValue = "Waiting for your answer…"
        FinderTakeover.requestAutomationPermission { [weak self] granted in
            guard let self else { return }
            self.permissionButton.isEnabled = true
            if !granted {
                self.permissionStatus.stringValue =
                    "Refused. System Settings › Privacy & Security › Automation can change it."
            }
            self.refresh()
        }
    }

    @objc private func giveBack() {
        FinderTakeover.giveBackToFinder()
        refresh()
    }
}
