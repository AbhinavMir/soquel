import Foundation

/// Asking a model how a folder should be arranged, and turning the answer into
/// moves that can be looked at before any of them happen.
///
/// Nothing here moves a file. It produces a plan; `CleanFolderPanel` shows it,
/// the person ticks what they want, and the ordinary transfer engine does the
/// work so the whole thing lands on the undo stack.
enum CleanFolder {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5"

    /// One proposed move.
    struct Step: Equatable {
        /// The file as it is now.
        let source: URL
        /// Where it would go, folders created as needed.
        let destination: URL
        /// Why, in the model's words, shown beside the row.
        let reason: String
        /// Set when the step cannot be used, with what is wrong.
        var problem: String?

        var isRename: Bool {
            source.deletingLastPathComponent() == destination.deletingLastPathComponent()
        }
        var newFolder: String? {
            let parent = destination.deletingLastPathComponent()
            return parent == source.deletingLastPathComponent() ? nil : parent.lastPathComponent
        }
    }

    struct Plan: Equatable {
        let steps: [Step]
        /// A sentence on what the arrangement is, for the top of the panel.
        let summary: String
        var usable: [Step] { steps.filter { $0.problem == nil } }
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case network(String)
        case unreadable(String)
        case nothingToDo

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key. Settings › Clean adds one."
            case .http(let code, let message):
                return code == 401
                    ? "The API key was refused. Settings › Clean can replace it."
                    : "The service answered \(code): \(message)"
            case .network(let why): return "Could not reach the service: \(why)"
            case .unreadable(let why): return "The answer could not be read: \(why)"
            case .nothingToDo: return "This folder already looks arranged."
            }
        }
    }

    // MARK: - Asking

    /// The tool the model must call, which is how the answer arrives as data
    /// rather than as prose to be parsed out of a paragraph.
    static var tool: [String: Any] {
        [
            "name": "propose_structure",
            "description": "Propose where each file should go.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "One sentence describing the arrangement."
                    ],
                    "moves": [
                        "type": "array",
                        "description": "One entry per file that should move or be renamed. Leave a file out if it is already in the right place.",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "properties": [
                                "file": ["type": "string", "description": "The file's name, exactly as given."],
                                "destination": ["type": "string", "description": "Path relative to the folder being cleaned, or an absolute path inside one of the listed global folders. Include the file name."],
                                "reason": ["type": "string", "description": "Why, in one short clause."]
                            ],
                            "required": ["file", "destination", "reason"]
                        ]
                    ]
                ],
                "required": ["summary", "moves"]
            ]
        ]
    }

    static func systemPrompt(for folder: URL) -> String {
        var text = """
        You are arranging one folder for somebody who will review every move before it happens.

        Rules:
        - Group by what files are, not by extension alone. A folder of one file is not a group.
        - Keep names unless a name is actively unhelpful. Renaming everything is not tidying.
        - Leave a file out of the list if it is already where it belongs.
        - Never propose deleting anything. There is no delete.
        - A destination is either relative to the folder being cleaned, or an absolute path inside one of the global folders listed below.
        - Prefer fewer, clearer folders over a deep tree.
        """
        if let note = FolderContext.note(for: folder) {
            text += "\n\nWhat this folder is for, in the owner's words: \(note)"
        }
        let destinations = FolderContext.destinations()
        if !destinations.isEmpty {
            text += "\n\nGlobal folders. Files may be filed into these from anywhere, "
                + "even with nothing written about them:\n"
            for (url, note) in destinations {
                text += "- \(url.path)"
                if let note { text += " — \(note)" }
                text += "\n"
            }
        }
        return text
    }

    static func requestBody(for folder: URL, payload: CleanSanitiser.Payload) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],
            "system": systemPrompt(for: folder),
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "propose_structure"],
            "messages": [[
                "role": "user",
                "content": "Folder: \(folder.path)\n\nContents, with the first "
                    + "\(CleanSanitiser.headBytes) bytes of each text file:\n\n"
                    + CleanSanitiser.preview(payload)
            ]]
        ]
    }

    static func propose(folder: URL, payload: CleanSanitiser.Payload,
                        session: URLSession = .shared,
                        completion: @escaping (Result<Plan, Error>) -> Void) {
        guard let key = APICredentials.key() else {
            completion(.failure(Failure.noKey))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody(for: folder, payload: payload))

        session.dataTask(with: request) { data, response, error in
            func finish(_ result: Result<Plan, Error>) {
                DispatchQueue.main.async { completion(result) }
            }
            if let error { return finish(.failure(Failure.network(error.localizedDescription))) }
            guard let data else { return finish(.failure(Failure.network("nothing came back"))) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                    ?? String(decoding: data.prefix(200), as: UTF8.self)
                return finish(.failure(Failure.http(http.statusCode, message)))
            }
            finish(parse(data, folder: folder))
        }.resume()
    }

    // MARK: - Reading the answer

    /// Pulls the tool call out of the response and checks every move before it
    /// is shown. A destination outside what is allowed is kept in the list with
    /// the reason it cannot be used, rather than dropped — a plan that quietly
    /// loses entries reads as a plan the model did not make.
    static func parse(_ data: Data, folder: URL) -> Result<Plan, Error> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]]
        else { return .failure(Failure.unreadable("no content")) }

        guard let call = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = call["input"] as? [String: Any]
        else { return .failure(Failure.unreadable("the model did not answer with a plan")) }

        let summary = input["summary"] as? String ?? "A suggested arrangement."
        let moves = input["moves"] as? [[String: Any]] ?? []
        guard !moves.isEmpty else { return .failure(Failure.nothingToDo) }

        var steps: [Step] = []
        var claimed = Set<String>()
        for move in moves {
            guard let file = move["file"] as? String,
                  let destination = move["destination"] as? String
            else { continue }
            let reason = move["reason"] as? String ?? ""
            steps.append(step(file: file, destination: destination, reason: reason,
                              folder: folder, claimed: &claimed))
        }
        guard !steps.isEmpty else { return .failure(Failure.unreadable("the plan held no usable moves")) }
        return .success(Plan(steps: steps, summary: summary))
    }

    static func step(file: String, destination: String, reason: String,
                     folder: URL, claimed: inout Set<String>) -> Step {
        let source = folder.appendingPathComponent(file)
        let target: URL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination).standardized
            : folder.appendingPathComponent(destination).standardized

        var step = Step(source: source, destination: target, reason: reason, problem: nil)

        // The name has to be one the folder actually holds. A model that
        // invented a filename must not have a row that looks actionable.
        if file.contains("/") || file == ".." || file == "." {
            step.problem = "Not a file in this folder"
        } else if !FileManager.default.fileExists(atPath: source.path) {
            step.problem = "No longer here"
        } else if !FolderContext.isAllowedDestination(target, cleaning: folder) {
            step.problem = "Outside this folder and outside every global folder"
        } else if target == source {
            step.problem = "Already there"
        } else if FileManager.default.fileExists(atPath: target.path) {
            step.problem = "Something is already called that"
        } else if claimed.contains(target.standardizedFileURL.path.lowercased()) {
            step.problem = "Two files would end up with this name"
        }
        claimed.insert(target.standardizedFileURL.path.lowercased())
        return step
    }
}
