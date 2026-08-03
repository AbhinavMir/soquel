import AppKit

/// Sharing a theme as a gist or a git repository.
///
/// There is still one theme format, and it is `theme.json`. A gist holds that
/// same file verbatim, and a repository holds it at the top level under that
/// name — nothing is wrapped, renamed or converted. A theme someone sends is a
/// file you could equally have written by hand, and the thing you paste back
/// out is the file you already have.
///
/// A repository is the better home for one you keep working on: it has a
/// history, it takes pull requests, and the address does not change when you
/// edit it.
enum ThemeSharing {
    /// Where a pasted address points.
    enum Source: Equatable {
        case gist(String)
        /// owner and repository, and the branch or tag to read from.
        case repository(owner: String, name: String, ref: String)

        /// A file beside theme.json in the same repository. Gists hold one
        /// flat list of text files and cannot carry a picture, so only a
        /// repository has anything to point at.
        func url(forRelative path: String) -> URL? {
            guard case .repository(let owner, let name, let ref) = self else { return nil }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            guard !trimmed.isEmpty, let escaped = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) else { return nil }
            return URL(string:
                "https://raw.githubusercontent.com/\(owner)/\(name)/\(ref)/\(escaped)")
        }

        /// Where the JSON actually lives.
        var url: URL? {
            switch self {
            case .gist(let id):
                return URL(string: "https://api.github.com/gists/\(id)")
            case .repository(let owner, let name, let ref):
                return URL(string:
                    "https://raw.githubusercontent.com/\(owner)/\(name)/\(ref)/theme.json")
            }
        }
    }

    /// Reads whichever of the two was pasted.
    ///
    /// A gist id is a long hex string and a repository is owner/name, so the
    /// two never collide.
    static func source(from input: String) -> Source? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = gistID(from: text) { return .gist(id) }
        return repository(from: text)
    }

    /// Accepts the page URL, the clone URL, and bare `owner/name`, with an
    /// optional branch or tag after a hash.
    static func repository(from input: String) -> Source? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        var ref = "HEAD"
        if let hash = text.firstIndex(of: "#") {
            let named = String(text[text.index(after: hash)...])
            if !named.isEmpty { ref = named }
            text = String(text[..<hash])
        }

        var path = text
        if let url = URL(string: text), let host = url.host?.lowercased() {
            guard host.hasSuffix("github.com") else { return nil }
            path = url.path
        } else if text.contains("://") || text.contains("@") {
            // Something that looks like a URL but is not GitHub, or an SSH
            // remote for a host we cannot read over HTTPS.
            guard text.hasPrefix("git@github.com:") else { return nil }
            path = String(text.dropFirst("git@github.com:".count))
        }

        let parts = path
            .replacingOccurrences(of: ".git", with: "")
            .split(separator: "/")
            .map(String.init)
        guard parts.count >= 2 else { return nil }

        // github.com/owner/name/tree/branch names the branch in the path.
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            return .repository(owner: parts[0], name: parts[1], ref: parts[3])
        }
        guard parts.count == 2 else { return nil }
        return .repository(owner: parts[0], name: parts[1], ref: ref)
    }
    enum Failure: LocalizedError, Equatable {
        case notAGist(String)
        case network(String)
        case noJSON
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notAGist(let text):
                return "“\(text)” is not a gist or a GitHub repository."
            case .network(let reason):
                return "Could not reach GitHub: \(reason)"
            case .noJSON:
                return "That gist has no JSON file in it."
            case .unreadable:
                return "That file is not a Soquel theme."
            }
        }
    }

    /// The gist's id, from any of the forms someone might paste.
    ///
    /// Accepts the page URL, the raw URL, the API URL, and the bare id, because
    /// which one you have depends on whether you copied from the address bar or
    /// the Raw button.
    static func gistID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A bare id is 20 or more hex characters.
        if text.count >= 20, text.allSatisfy(\.isHexDigit) { return text }

        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              host.hasSuffix("github.com") || host.hasSuffix("githubusercontent.com")
        else { return nil }

        // The id is the last path component that looks like one: gist.github.com
        // puts it after the user name, the raw URL puts revisions after it.
        return url.pathComponents.last { $0.count >= 20 && $0.allSatisfy(\.isHexDigit) }
    }

    static func apiURL(for id: String) -> URL? {
        URL(string: "https://api.github.com/gists/\(id)")
    }

    /// Pulls the theme out of a gist's API response.
    ///
    /// Kept apart from the request so the parsing can be checked without one.
    static func theme(fromGist data: Data) -> Result<ThemeConfig, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: [String: Any]]
        else { return .failure(.unreadable) }

        // theme.json first, then any other .json, so a gist with a README in it
        // still works.
        let ordered = files.sorted { a, b in
            if (a.key == "theme.json") != (b.key == "theme.json") { return a.key == "theme.json" }
            return a.key < b.key
        }
        let candidates = ordered.filter { $0.key.lowercased().hasSuffix(".json") }
        guard !candidates.isEmpty else { return .failure(.noJSON) }

        for (_, file) in candidates {
            guard let content = file["content"] as? String,
                  let config = decode(content)
            else { continue }
            return .success(config)
        }
        return .failure(.unreadable)
    }

    /// A theme is only a theme if it sets at least one colour we know.
    ///
    /// Without this any JSON at all decodes into an empty config and "applies"
    /// silently, leaving the colours untouched and the user told it worked.
    static func decode(_ text: String) -> ThemeConfig? {
        guard let data = text.data(using: .utf8),
              let config = try? JSONDecoder().decode(ThemeConfig.self, from: data)
        else { return nil }

        let known = Set(ThemeConfig.Slot.allCases.map(\.rawValue))
        let named = Set(config.light.keys).union(config.dark.keys)
        guard !named.intersection(known).isEmpty else { return nil }
        return sanitised(config)
    }

    /// Strips what cannot mean anything on another machine.
    ///
    /// An absolute path is the sender's disk. It either does not exist here or,
    /// worse, points at a different picture of yours, so it goes. A relative
    /// one names a file inside the repository the theme came from, which is the
    /// whole reason to put a theme in a repository rather than a gist — that
    /// one is kept and fetched.
    static func sanitised(_ config: ThemeConfig) -> ThemeConfig {
        var copy = config
        guard let background = copy.background else { return copy }
        guard let path = background.imagePath, isRelative(path) else {
            copy.background = nil
            return copy
        }
        return copy
    }

    /// Whether a stored path names a file inside the theme's own repository.
    ///
    /// Anything absolute, anything reaching upwards, and anything with a scheme
    /// is refused: a theme may bring its own picture and may not read yours or
    /// pull one from somewhere else.
    static func isRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard !path.contains("://"), !path.contains("..") else { return false }
        return true
    }

    /// Where a downloaded picture is kept: beside the theme, under the
    /// repository it came from, so installing a second theme cannot overwrite
    /// the first one's background.
    static func mediaDirectory(for source: Source) -> URL? {
        guard case .repository(let owner, let name, _) = source else { return nil }
        let safe = "\(owner)-\(name)".replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression
        )
        return ThemeConfig.directoryURL
            .appendingPathComponent("theme-images", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    /// A picture that will not fit on screen is a picture nobody chose, and an
    /// unbounded download from a stranger is not something to start.
    static let maximumImageBytes = 20 * 1024 * 1024

    /// Downloads the picture a repository theme points at and rewrites the
    /// path to the local copy.
    ///
    /// The config is handed back unchanged when there is nothing to fetch or
    /// the fetch fails: a theme whose background did not arrive is still a
    /// usable theme, and is better than refusing the colours over a picture.
    static func fetchImage(
        for config: ThemeConfig,
        from source: Source,
        session: URLSession = .shared,
        completion: @escaping (ThemeConfig) -> Void
    ) {
        guard let path = config.background?.imagePath, isRelative(path),
              let url = source.url(forRelative: path),
              let directory = mediaDirectory(for: source)
        else {
            completion(config)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Soquel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        session.dataTask(with: request) { data, response, _ in
            var updated = config
            defer { DispatchQueue.main.async { completion(updated) } }

            guard let data, !data.isEmpty, data.count <= maximumImageBytes,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  NSImage(data: data) != nil
            else {
                // Not an image, too big, or not there. Keep the colours and
                // drop the background rather than leaving a path to nothing.
                updated.background = nil
                return
            }

            let name = (path as NSString).lastPathComponent
            let destination = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try data.write(to: destination)
                updated.background?.imagePath = destination.path
            } catch {
                updated.background = nil
            }
        }.resume()
    }

    /// Fetches and parses. The completion runs on the main queue.
    static func fetch(
        _ input: String,
        session: URLSession = .shared,
        completion: @escaping (Result<(ThemeConfig, Source), Failure>) -> Void
    ) {
        guard let source = source(from: input), let url = source.url else {
            completion(.failure(.notAGist(input)))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Soquel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        session.dataTask(with: request) { data, response, error in
            let outcome: Result<(ThemeConfig, Source), Failure>
            if let error {
                outcome = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failure(.network("answered \(http.statusCode)"))
            } else if let data {
                // A gist comes back as the API's file listing; a repository
                // comes back as the file itself.
                switch source {
                case .gist:
                    outcome = theme(fromGist: data).map { ($0, source) }
                case .repository:
                    outcome = String(data: data, encoding: .utf8)
                        .flatMap(decode)
                        .map { .success(($0, source)) } ?? .failure(.unreadable)
                }
            } else {
                outcome = .failure(.unreadable)
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    /// What goes in the gist: the colours as they are now, without the
    /// background, which is a path only meaningful on this machine.
    static func exportText() -> String {
        let config = sanitised(Theme.config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// A one-line description of what a theme would change, for the confirm.
    static func summary(_ config: ThemeConfig) -> String {
        let light = config.light.count
        let dark = config.dark.count
        return "\(light) light colour\(light == 1 ? "" : "s"), "
            + "\(dark) dark colour\(dark == 1 ? "" : "s")"
    }
}
