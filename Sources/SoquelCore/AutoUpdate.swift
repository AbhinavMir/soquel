import AppKit

/// Keeping the application current, on the channel the user picked.
///
/// The plain update check tells you and stops. This one can finish the job: it
/// downloads the release, checks the signature, replaces the copy on disk and
/// restarts. That is a bigger promise, so it is off until it is asked for, and
/// it is the same `Installer` the faulty-build notice uses — one path that
/// verifies before it replaces, not two.
enum AutoUpdate {
    /// Every release, newest first, rather than only the one GitHub calls
    /// latest. A nightly is marked prerelease, and `releases/latest` never
    /// returns a prerelease, so the nightly channel has to read the list.
    static let endpoint = URL(string:
        "https://api.github.com/repos/AbhinavMir/soquel/releases?per_page=30")!

    struct Release: Equatable {
        let version: Version
        let page: URL
        let notes: String?
        let isPrerelease: Bool
    }

    // MARK: - Settings

    /// Download and install on its own, or only say that something is out.
    static var installsAutomatically: Bool {
        get { Settings.object(forKey: "autoInstallUpdates") as? Bool ?? false }
        set { Settings.set(newValue, forKey: "autoInstallUpdates") }
    }

    static var lastChecked: Date? {
        get { Settings.double(forKey: "lastChannelCheck").map(Date.init(timeIntervalSince1970:)) }
        set { Settings.set(newValue?.timeIntervalSince1970, forKey: "lastChannelCheck") }
    }

    /// Nightlies move faster than sequential releases, so they are asked about
    /// more often. Neither is checked on every launch.
    static var interval: TimeInterval {
        UpdateChannel.current == .nightly ? 60 * 60 * 6 : 60 * 60 * 24
    }

    static var currentVersion: Version {
        Version(UpdateCheck.currentVersion) ?? Version(0, 0, 0)
    }

    // MARK: - Reading the list

    /// Turns the API's answer into releases. A draft is skipped; a prerelease
    /// is kept, because that is what a nightly is.
    static func parse(_ data: Data) -> [Release] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard item["draft"] as? Bool != true,
                  let tag = item["tag_name"] as? String,
                  let version = Version(tag)
            else { return nil }
            let page = (item["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/AbhinavMir/soquel/releases")!
            return Release(version: version, page: page,
                           notes: item["body"] as? String,
                           isPrerelease: item["prerelease"] as? Bool ?? false)
        }
    }

    /// The newest release on this channel that is newer than what is running.
    ///
    /// The channel decides by version number, not by GitHub's prerelease flag.
    /// A sequential release marked prerelease while it is being tried out is
    /// still a sequential release, and somebody on stable should get it.
    static func best(from releases: [Release], channel: UpdateChannel,
                     current: Version) -> Release? {
        releases
            .filter { $0.version.suits(channel) && $0.version > current }
            .max { $0.version < $1.version }
    }

    static func check(session: URLSession = .shared,
                      completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Soquel/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        session.dataTask(with: request) { data, _, _ in
            let found = data.map {
                best(from: parse($0), channel: .current, current: currentVersion)
            } ?? nil
            DispatchQueue.main.async {
                lastChecked = Date()
                completion(found)
            }
        }.resume()
    }

    // MARK: - On launch

    static func isDue(now: Date = Date()) -> Bool {
        guard let last = lastChecked else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Runs at startup. Says nothing unless there is a release to offer.
    static func checkOnLaunch() {
        guard UpdateCheck.isEnabled, isDue() else { return }
        check { release in
            guard let release else { return }
            Log.info(.app, "\(UpdateChannel.current.rawValue) channel offers \(release.version)")
            if installsAutomatically {
                install(release)
            } else {
                offer(release)
            }
        }
    }

    /// Installs without asking, because being asked is what the setting turned
    /// off. It still says what happened, and it still refuses an unsigned
    /// download — automatic never means unchecked.
    static func install(_ release: Release) {
        Installer.install(version: release.version.description) { step in
            Log.info(.app, "auto update: \(step)")
        } completion: { result in
            switch result {
            case .success(let version):
                let alert = NSAlert()
                alert.messageText = "Soquel \(version) is installed"
                alert.informativeText = "It was downloaded and put in place automatically. "
                    + "Restart to use it. Settings › Updates turns this off."
                alert.addButton(withTitle: "Restart Now")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { Installer.relaunch() }
            case .failure(let error):
                // A failed automatic update must not be silent: the copy that
                // is running is now known to be behind.
                Log.info(.app, "auto update failed: \(error.localizedDescription)")
                offer(release, failure: error.localizedDescription)
            }
        }
    }

    /// Tells, and offers to finish the job in one click.
    static func offer(_ release: Release, failure: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Soquel \(release.version) is out"
        var body = "You have \(currentVersion), on the "
            + "\(UpdateChannel.current == .nightly ? "nightly" : "sequential") channel."
        if let failure { body += "\n\nInstalling it automatically did not work: \(failure)" }
        body += "\n\nInstalling checks the signature before anything is replaced."
        alert.informativeText = body
        alert.addButton(withTitle: "Install \(release.version)")
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AdvisoryPanel.installOrReport(release.version.description)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }
}
