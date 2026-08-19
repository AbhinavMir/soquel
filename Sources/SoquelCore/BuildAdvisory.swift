import AppKit

/// A recall notice for a build that turned out to be bad.
///
/// The update check asks whether something newer exists. This asks a different
/// question: is the build you are running known to be harmful? The two are
/// deliberately separate. An update is an offer and stays off until you ask
/// for it. A recall is a warning about the copy already on your disk, so it is
/// on by default — Settings › General turns it off, and turning it off is
/// respected with no second asking.
///
/// The list is a static file on the site. Nothing about this machine is sent:
/// the request carries a version in the user agent and nothing else, and the
/// answer is the same file every reader gets. Which advisory applies is worked
/// out here, on the machine, not by a server that was told what is installed.
enum BuildAdvisory {
    static let endpoint = URL(string: "https://trysoquel.com/advisories.json")!

    /// How bad the build is, which decides whether the notice interrupts.
    enum Severity: String {
        /// Loses or damages data. Says so on launch, before anything is opened.
        case critical
        /// Wrong results or a hang. Sits in a bar at the top of the window.
        case serious

        var isInterrupting: Bool { self == .critical }
    }

    struct Advisory {
        /// Exact versions this applies to. An exact list, never a range: a
        /// range that is one character wrong condemns builds that are fine.
        let affects: [String]
        let severity: Severity
        /// One line, shown as the headline.
        let summary: String
        /// What goes wrong, in full.
        let detail: String
        /// The version that fixes it. Nil when there is no fix out yet.
        let fixedIn: String?
        /// The last version before the defect went in, for going back when
        /// there is no fix yet or the fix is not wanted.
        let rollBackTo: String?

        func applies(to version: String) -> Bool { affects.contains(version) }
    }

    // MARK: - Settings

    /// On by default. This is the one request Soquel makes without being
    /// asked, and it is made because a build that destroys a file is not
    /// something to stay quiet about.
    static var isEnabled: Bool {
        get { Settings.object(forKey: "checkForBadBuilds") as? Bool ?? true }
        set { Settings.set(newValue, forKey: "checkForBadBuilds") }
    }

    /// An advisory the user has read and chosen to live with. Recorded per
    /// version, so a later bad build is not silenced by a dismissal of an
    /// earlier one.
    static var acknowledged: String? {
        get { Settings.object(forKey: "acknowledgedAdvisory") as? String }
        set { Settings.set(newValue, forKey: "acknowledgedAdvisory") }
    }

    static var currentVersion: String { UpdateCheck.currentVersion }

    // MARK: - Reading the list

    /// Parses the published file. A malformed entry is skipped rather than
    /// failing the whole list: one bad record must not hide a real recall.
    static func parse(_ data: Data) -> [Advisory] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["advisories"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let affects = item["affects"] as? [String], !affects.isEmpty,
                  let severity = (item["severity"] as? String).flatMap(Severity.init(rawValue:)),
                  let summary = item["summary"] as? String, !summary.isEmpty
            else { return nil }
            return Advisory(
                affects: affects,
                severity: severity,
                summary: summary,
                detail: item["detail"] as? String ?? "",
                fixedIn: item["fixedIn"] as? String,
                rollBackTo: item["rollBackTo"] as? String
            )
        }
    }

    /// The advisory for a version, worst first when more than one applies.
    static func advisory(for version: String, in list: [Advisory]) -> Advisory? {
        let matching = list.filter { $0.applies(to: version) }
        return matching.first { $0.severity == .critical } ?? matching.first
    }

    static func fetch(session: URLSession = .shared,
                      completion: @escaping (Advisory?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.setValue("Soquel/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        session.dataTask(with: request) { data, _, _ in
            let found = data.map { advisory(for: currentVersion, in: parse($0)) } ?? nil
            DispatchQueue.main.async { completion(found) }
        }.resume()
    }

    // MARK: - On launch

    /// Runs once at startup. Silent unless this exact build is on the list.
    static func checkOnLaunch() {
        guard isEnabled else { return }
        fetch { advisory in
            guard let advisory else { return }
            Log.info(.app, "build advisory for \(currentVersion): \(advisory.summary)")
            guard advisory.severity.isInterrupting || acknowledged != currentVersion else { return }
            AdvisoryPanel.show(advisory)
        }
    }
}
