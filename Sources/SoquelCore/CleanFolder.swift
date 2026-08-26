import Foundation

/// Asking a model how a folder should be arranged, and turning the answer into
/// moves that can be looked at before any of them happen.
///
/// Nothing here moves a file. It produces a plan; `CleanFolderPanel` shows it,
/// the person ticks what they want, and the ordinary transfer engine does the
/// work so the whole thing lands on the undo stack.
enum CleanFolder {

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
        case notReady(String)
        case noKey
        case http(Int, String)
        case network(String)
        case unreadable(String)
        case nothingToDo

        var errorDescription: String? {
            switch self {
            case .notReady(let why): return why
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

    static func userMessage(for folder: URL, payload: CleanSanitiser.Payload) -> String {
        "Folder: \(folder.path)\n\nContents, with the first "
            + "\(CleanSanitiser.headBytes) bytes of each text file:\n\n"
            + CleanSanitiser.preview(payload)
    }

    /// The request, in whichever shape the chosen provider speaks.
    ///
    /// The two differ in more than the URL: the key goes in a different header,
    /// the system prompt is a field in one and a message in the other, and a
    /// tool's schema is called `input_schema` in one and `parameters` in the
    /// other. Everything else here is the same question.
    static func requestBody(for folder: URL, payload: CleanSanitiser.Payload,
                            provider: LLMProvider = .current,
                            model: String = LLMProvider.currentModel) -> [String: Any] {
        let system = systemPrompt(for: folder)
        let user = userMessage(for: folder, payload: payload)

        switch provider.wire {
        case .anthropic:
            return [
                "model": model,
                "max_tokens": 16000,
                "thinking": ["type": "adaptive"],
                "output_config": ["effort": "high"],
                "system": system,
                "tools": [tool],
                "tool_choice": ["type": "tool", "name": "propose_structure"],
                "messages": [["role": "user", "content": user]]
            ]
        case .openai:
            return [
                "model": model,
                "max_tokens": 16000,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "propose_structure",
                        "description": "Propose where each file should go.",
                        "parameters": tool["input_schema"] as Any
                    ]
                ]],
                "tool_choice": [
                    "type": "function",
                    "function": ["name": "propose_structure"]
                ]
            ]
        }
    }

    static func request(for folder: URL, payload: CleanSanitiser.Payload,
                        provider: LLMProvider = .current,
                        model: String = LLMProvider.currentModel) -> URLRequest? {
        guard let url = provider.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let key = APICredentials.key(for: provider.id)
        switch provider.wire {
        case .anthropic:
            key.map { request.setValue($0, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            // A local server wants no key and is given none.
            key.map { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: requestBody(for: folder, payload: payload,
                                        provider: provider, model: model))
        return request
    }

    static func propose(folder: URL, payload: CleanSanitiser.Payload,
                        session: URLSession = .shared,
                        completion: @escaping (Result<Plan, Error>) -> Void) {
        let ready = LLMProvider.isReady()
        guard ready.ok else {
            completion(.failure(Failure.notReady(ready.missing ?? "Not set up yet.")))
            return
        }
        guard let request = request(for: folder, payload: payload) else {
            completion(.failure(Failure.notReady("That address cannot be used.")))
            return
        }
        session.dataTask(with: request) { data, response, error in
            func finish(_ result: Result<Plan, Error>) {
                DispatchQueue.main.async { completion(result) }
            }
            if let error { return finish(.failure(Failure.network(error.localizedDescription))) }
            guard let data else { return finish(.failure(Failure.network("nothing came back"))) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // Both wires wrap the reason in "error", though one nests it
                // under "message" and some servers answer with plain text.
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { root -> String? in
                        if let error = root?["error"] as? [String: Any] {
                            return error["message"] as? String
                        }
                        return root?["error"] as? String
                    }
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
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(Failure.unreadable("the answer was not JSON")) }
        guard let input = toolInput(in: root)
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

    /// Digs the arguments out of whichever shape came back.
    ///
    /// Three shapes are accepted. Anthropic puts a `tool_use` block in
    /// `content`. The `/chat/completions` shape puts a `tool_calls` entry on
    /// the message, with its arguments as a *string* of JSON rather than an
    /// object. And a small model running locally often ignores the tool
    /// altogether and writes the JSON into its reply, which is worth reading
    /// rather than refusing — the alternative is telling somebody their own
    /// hardware is not good enough when the answer is right there.
    static func toolInput(in root: [String: Any]) -> [String: Any]? {
        // Anthropic.
        if let content = root["content"] as? [[String: Any]],
           let call = content.first(where: { $0["type"] as? String == "tool_use" }),
           let input = call["input"] as? [String: Any] {
            return input
        }
        let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        // OpenAI-shaped tool call. Arguments arrive as a JSON string.
        if let calls = message?["tool_calls"] as? [[String: Any]],
           let arguments = (calls.first?["function"] as? [String: Any])?["arguments"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] {
            return parsed
        }
        // The model answered in prose. Take the outermost JSON object it wrote.
        let text = (message?["content"] as? String)
            ?? (root["content"] as? [[String: Any]])?
                .first(where: { $0["type"] as? String == "text" })?["text"] as? String
        if let text, let object = firstJSONObject(in: text),
           object["moves"] != nil {
            return object
        }
        return nil
    }

    /// The first balanced `{...}` in a string, so a plan wrapped in a fenced
    /// code block or a sentence of preamble still reads.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let slice = String(characters[start...index])
                    return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
                }
            }
        }
        return nil
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
