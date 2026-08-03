import AppKit

/// Sharing a theme as a GitHub gist.
///
/// There is still one theme format, and it is `theme.json`. A gist holds that
/// same file verbatim — nothing is wrapped, renamed or converted, so a theme
/// someone sends is a file you could equally have written by hand, and the
/// thing you paste back out is the file you already have.
enum ThemeSharing {
    enum Failure: LocalizedError, Equatable {
        case notAGist(String)
        case network(String)
        case noJSON
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notAGist(let text):
                return "“\(text)” is not a gist address."
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
    /// A background image is stored as a path. Someone else's path either does
    /// not exist here or, worse, points at a different picture of yours, so a
    /// downloaded theme keeps the colours and leaves the background alone.
    static func sanitised(_ config: ThemeConfig) -> ThemeConfig {
        var copy = config
        copy.background = nil
        return copy
    }

    /// Fetches and parses. The completion runs on the main queue.
    static func fetch(
        _ input: String,
        session: URLSession = .shared,
        completion: @escaping (Result<ThemeConfig, Failure>) -> Void
    ) {
        guard let id = gistID(from: input), let url = apiURL(for: id) else {
            completion(.failure(.notAGist(input)))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Soquel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        session.dataTask(with: request) { data, response, error in
            let outcome: Result<ThemeConfig, Failure>
            if let error {
                outcome = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failure(.network("answered \(http.statusCode)"))
            } else if let data {
                outcome = theme(fromGist: data)
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
