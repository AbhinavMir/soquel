import AppKit

/// Telling somebody the copy they are running is bad, and offering the two
/// ways out in one click each.
///
/// The wording says what breaks and what it costs. A recall that hedges gets
/// dismissed, and the person keeps running the build that loses their files.
enum AdvisoryPanel {
    private static var showing = false

    static func show(_ advisory: BuildAdvisory.Advisory) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        let alert = NSAlert()
        alert.alertStyle = advisory.severity == .critical ? .critical : .warning
        alert.messageText = advisory.severity == .critical
            ? "Soquel \(BuildAdvisory.currentVersion) has a fault that loses data"
            : "Soquel \(BuildAdvisory.currentVersion) has a known fault"

        var body = advisory.summary
        if !advisory.detail.isEmpty { body += "\n\n" + advisory.detail }
        body += "\n\nBoth buttons below download from Soquel's own release page, "
            + "check the signature, replace this copy and restart."
        alert.informativeText = body

        // Ordered by what somebody should do, not by which is newer.
        var actions: [(String, () -> Void)] = []
        if let fixedIn = advisory.fixedIn {
            actions.append(("Install \(fixedIn)", { installOrReport(fixedIn) }))
        }
        if let rollBackTo = advisory.rollBackTo {
            actions.append(("Go Back to \(rollBackTo)", { installOrReport(rollBackTo) }))
        }
        for (title, _) in actions { alert.addButton(withTitle: title) }

        alert.addButton(withTitle: "Keep This Version")
        // Only offered where staying is a decision rather than a mistake.
        if advisory.severity != .critical {
            alert.addButton(withTitle: "Do Not Tell Me Again")
        }

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < actions.count {
            actions[index].1()
        } else if index == actions.count + 1 {
            BuildAdvisory.acknowledged = BuildAdvisory.currentVersion
        }
    }

    /// Runs the install with something on screen while it happens, because a
    /// download behind a dismissed dialog reads as a button that did nothing.
    static func installOrReport(_ version: String) {
        let progress = NSAlert()
        progress.messageText = "Installing Soquel \(version)"
        progress.informativeText = "Starting…"
        progress.addButton(withTitle: "Cancel")

        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        spinner.startAnimation(nil)
        progress.accessoryView = spinner

        let window = progress.window
        // The alert's own button ends the modal session and hands back which
        // one was pressed. That return value used to be discarded, so Cancel
        // closed the window and the install carried on to replace the
        // application regardless.
        var job: Installer.Job?
        DispatchQueue.main.async {
            let response = NSApp.runModal(for: window)
            if response == .alertFirstButtonReturn { job?.cancel() }
        }

        job = Installer.install(version: version) { step in
            progress.informativeText = step
        } completion: { result in
            NSApp.stopModal()
            window.orderOut(nil)

            if case .failure(let error) = result,
               (error as? Installer.Failure) == .cancelled {
                // Asked for and got. Nothing to report.
                return
            }

            switch result {
            case .success(let installed):
                let done = NSAlert()
                done.messageText = "Soquel \(installed) is installed"
                done.informativeText = "Soquel will restart now."
                done.addButton(withTitle: "Restart")
                done.runModal()
                Installer.relaunch()
            case .failure(let error):
                let failed = NSAlert()
                failed.alertStyle = .critical
                failed.messageText = "Nothing was installed"
                failed.informativeText = error.localizedDescription
                    + "\n\nThe copy you were running has not been touched. "
                    + "The release page has the disk image if you would rather "
                    + "do it by hand."
                failed.addButton(withTitle: "Open Release Page")
                failed.addButton(withTitle: "Close")
                if failed.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/AbhinavMir/soquel/releases")!)
                }
            }
        }
    }
}
