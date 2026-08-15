import AppKit

/// Asking GitHub whether there is a newer release.
///
/// Off unless it is turned on. When it is off nothing is requested and no
/// connection is made, which is the whole of the promise: a file manager has no
/// business talking to a server you did not ask it to talk to.
///
/// Even on, it only tells you. There is no download, no installer and no
/// background agent — the button opens the release page in a browser.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/AbhinavMir/soquel/releases/latest")!

    static var isEnabled: Bool {
        get { Settings.object(forKey: "checkForUpdates") as? Bool ?? false }
        set {
            Settings.set(newValue, forKey: "checkForUpdates")
            if !newValue { forgetState() }
        }
    }

    /// When it last asked, so turning it on does not mean asking on every
    /// launch and every settings visit.
    ///
    /// Stored as seconds since 1970: the settings file is JSON, which has no
    /// date type, so a Date handed to the store would be dropped rather than
    /// written — and a check that never records when it ran runs every launch.
    static var lastChecked: Date? {
        get { Settings.double(forKey: "lastUpdateCheck").map(Date.init(timeIntervalSince1970:)) }
        set { Settings.set(newValue?.timeIntervalSince1970, forKey: "lastUpdateCheck") }
    }

    /// The version the user said they did not want to be told about again.
    static var skippedVersion: String? {
        get { Settings.object(forKey: "skippedUpdateVersion") as? String }
        set { Settings.set(newValue, forKey: "skippedUpdateVersion") }
    }

    static let interval: TimeInterval = 60 * 60 * 24

    static func forgetState() {
        Settings.set(nil, forKey: "lastUpdateCheck")
        Settings.set(nil, forKey: "skippedUpdateVersion")
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release {
        let version: String
        let page: URL
        let notes: String?
    }

    enum Result {
        case upToDate
        case available(Release)
        case failed(String)
    }

    // MARK: - Comparing

    /// Splits "v1.0.2" or "1.0.2" into its numbers. A tag that is not a version
    /// gives nil rather than a guess.
    static func parse(_ tag: String) -> [Int]? {
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = trimmed.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // "1.0.2-beta1" stops at the dash rather than failing outright.
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// Whether `candidate` is newer than `current`. Unparseable either side is
    /// not newer: a tag nobody can read is not a reason to tell someone to
    /// upgrade.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Whether enough time has passed to ask again.
    static func isDue(now: Date = Date(), last: Date? = lastChecked, interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - Asking

    /// One request, no headers that identify anything beyond a user agent, and
    /// nothing sent about this machine or what is on it.
    static func check(
        session: URLSession = .shared,
        completion: @escaping (Result) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Soquel/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        session.dataTask(with: request) { data, response, error in
            let outcome = interpret(data: data, response: response, error: error)
            DispatchQueue.main.async {
                lastChecked = Date()
                completion(outcome)
            }
        }.resume()
    }

    /// Kept apart from the request so the parsing can be tested without one.
    static func interpret(data: Data?, response: URLResponse?, error: Error?) -> Result {
        if let error { return .failed(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failed("GitHub answered \(http.statusCode)")
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("Could not read the answer") }

        // A draft or a prerelease is not something to point anyone at.
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true {
            return .upToDate
        }
        guard isNewer(tag, than: currentVersion) else { return .upToDate }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/AbhinavMir/soquel/releases/latest")!
        return .available(Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            page: page,
            notes: json["body"] as? String
        ))
    }

    /// The check that runs on launch. Silent unless there is something to say.
    static func checkInBackgroundIfDue() {
        guard isEnabled, isDue() else { return }
        check { result in
            guard case .available(let release) = result,
                  release.version != skippedVersion
            else { return }
            announce(release)
        }
    }

    static func announce(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Soquel \(release.version) is out"
        alert.informativeText = "You have \(currentVersion). Nothing is downloaded or installed "
            + "automatically — the release page has the disk image."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.page)
        case .alertThirdButtonReturn:
            skippedVersion = release.version
        default:
            break
        }
    }
}
