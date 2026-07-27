import AppKit

/// Whether the application can read the whole disk, and how to say so.
///
/// None of this can be granted from code. The database that records these
/// permissions is protected by System Integrity Protection exactly so that no
/// program can grant itself access — an application that could would make the
/// permission meaningless. What an application can do is notice the permission
/// is missing, say plainly what it is for, and open the pane that grants it.
enum FullDiskAccess {
    /// A path only readable with Full Disk Access.
    ///
    /// Asking the system directly is not possible; the only honest test is to
    /// try reading something protected and see whether it is refused. This file
    /// is the one every application uses for the purpose, and it is opened
    /// read-only and immediately closed.
    private static var probe: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    static var isGranted: Bool {
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // No file to read means no answer either way. Treated as granted so
            // a machine that files it elsewhere is not nagged forever.
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    /// Opens the Full Disk Access list and shows the application in Finder, so
    /// it can be dragged in. The list cannot be added to from code either.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}

/// What Soquel can and cannot take over from Finder.
enum DefaultHandler {
    /// macOS refuses to let anything but Finder handle `public.folder`; the
    /// call returns paramErr. Volumes are allowed, which covers double-clicking
    /// a disk. Everything else is per-file "Open With".
    static let folderRoleIsReserved = true

    static func makeDefaultForVolumes() -> Bool {
        let id = Bundle.main.bundleIdentifier ?? "app.soquel.Soquel"
        return LSSetDefaultRoleHandlerForContentType(
            "public.volume" as CFString, .viewer, id as CFString) == noErr
    }

    static var isDefaultForVolumes: Bool {
        let id = Bundle.main.bundleIdentifier ?? "app.soquel.Soquel"
        guard let current = LSCopyDefaultRoleHandlerForContentType(
            "public.volume" as CFString, .viewer)?.takeRetainedValue() as String? else { return false }
        return current.caseInsensitiveCompare(id) == .orderedSame
    }
}

/// Shown once, on the first launch after installing.
///
/// The alternative is the application silently listing nothing in Desktop and
/// Documents while the person wonders what is broken — those folders are
/// protected, and a file manager that cannot read them looks defective rather
/// than unpermitted.
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private var accessRow: StepRow!
    private var volumeRow: StepRow!
    private var observer: NSObjectProtocol?

    /// Whether the first run has already been through this.
    static var hasBeenShown: Bool {
        get { Settings.bool(forKey: "welcomeShown") }
        set { Settings.set(newValue, forKey: "welcomeShown") }
    }

    /// Shows it on a first launch, and never again on its own.
    static func showIfFirstLaunch() {
        guard !hasBeenShown else { return }
        hasBeenShown = true
        // After the first window, so it is not talking to an empty screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shared.show() }
    }

    func show() {
        if window == nil { build() }
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func build() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = "Welcome to Soquel"
        panel.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Two things to set up")
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(wrappingLabelWithString:
            "Neither can be done for you — macOS only lets you grant them yourself.")
        blurb.font = Theme.rowSecondary
        blurb.textColor = .secondaryLabelColor
        blurb.translatesAutoresizingMaskIntoConstraints = false

        accessRow = StepRow(
            title: "Full Disk Access",
            detail: "Desktop, Documents and Downloads are protected by macOS. "
                + "Without this Soquel shows them as empty, which looks broken but is not.",
            buttonTitle: "Open Settings…",
            action: { [weak self] in
                FullDiskAccess.openSettings()
                self?.startWatchingForGrant()
            }
        )

        volumeRow = StepRow(
            title: "Open disks in Soquel",
            detail: "Double-clicking a disk opens it here instead of in Finder. "
                + "Folders cannot be reassigned — macOS keeps those for Finder.",
            buttonTitle: "Use Soquel",
            action: { [weak self] in
                _ = DefaultHandler.makeDefaultForVolumes()
                self?.refresh()
            }
        )

        let done = NSButton(title: "Done", target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let later = NSTextField(labelWithString: "You can reopen this from the Soquel menu.")
        later.font = Theme.status
        later.textColor = .tertiaryLabelColor
        later.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        for view in [icon, title, blurb, accessRow!, volumeRow!, done, later] as [NSView] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            blurb.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            blurb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            blurb.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            accessRow.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 26),
            accessRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            accessRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            volumeRow.topAnchor.constraint(equalTo: accessRow.bottomAnchor, constant: 18),
            volumeRow.leadingAnchor.constraint(equalTo: accessRow.leadingAnchor),
            volumeRow.trailingAnchor.constraint(equalTo: accessRow.trailingAnchor),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            later.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            later.centerYAnchor.constraint(equalTo: done.centerYAnchor),
        ])

        window = panel

        // Granting happens in System Settings, in another process, so the only
        // way to notice is to look again when the window comes back.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    /// Checks a few times after sending someone to System Settings, so the tick
    /// appears without them having to click back and forth to prompt it.
    private func startWatchingForGrant() {
        for delay in stride(from: 2.0, through: 20.0, by: 2.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        accessRow?.setDone(FullDiskAccess.isGranted)
        volumeRow?.setDone(DefaultHandler.isDefaultForVolumes)
    }

    @objc private func close(_ sender: Any?) { window?.close() }
}

/// One numbered step: what it is, why, and a button that does as much of it as
/// is possible from here.
private final class StepRow: NSView {
    private let button: NSButton
    private let tick: NSTextField
    private let action: () -> Void

    init(title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) {
        self.action = action
        button = NSButton(title: buttonTitle, target: nil, action: nil)
        tick = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.target = self
        button.action = #selector(run)
        button.translatesAutoresizingMaskIntoConstraints = false

        tick.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        tick.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        name.translatesAutoresizingMaskIntoConstraints = false

        let why = NSTextField(wrappingLabelWithString: detail)
        why.font = Theme.rowSecondary
        why.textColor = .secondaryLabelColor
        why.translatesAutoresizingMaskIntoConstraints = false

        for view in [name, why, button, tick] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),

            tick.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            tick.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            why.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            why.leadingAnchor.constraint(equalTo: leadingAnchor),
            why.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -14),
            why.bottomAnchor.constraint(equalTo: bottomAnchor),

            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { action() }

    func setDone(_ done: Bool) {
        tick.stringValue = done ? "✓" : ""
        tick.textColor = .systemGreen
        button.isEnabled = !done
        button.title = done ? "Done" : button.title
    }
}
