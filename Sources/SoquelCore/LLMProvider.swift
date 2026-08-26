import Foundation

/// Where Clean This Folder sends its question.
///
/// Not Anthropic, particularly. Two wire formats cover nearly everything:
/// Anthropic's own, and the `/chat/completions` shape that OpenAI defined and
/// that Ollama, LM Studio, llama.cpp, OpenRouter, GLM, Groq, DeepSeek and
/// Together all answer to. Anything speaking either can be typed in as a
/// custom provider.
///
/// A model running on this machine needs no key and no network, which for a
/// feature that reads your files is the best answer available. The local
/// presets are listed first for that reason.
struct LLMProvider: Equatable {
    enum Wire: String, Equatable {
        /// `POST /v1/messages`, `x-api-key`, tools with `input_schema`.
        case anthropic
        /// `POST /v1/chat/completions`, `Authorization: Bearer`, tools with
        /// `parameters`. What almost everything else speaks.
        case openai
    }

    let id: String
    let name: String
    /// The full URL a request goes to.
    let endpoint: String
    let wire: Wire
    /// False for a server on this machine, which wants no key.
    let needsKey: Bool
    /// Offered as a starting point; the model is a plain text field, because a
    /// list baked in here is out of date the week after it is written.
    let suggestedModel: String
    /// Where to get a key, shown beside the field.
    let keyURL: String?
    /// True for a server expected on this machine.
    let isLocal: Bool

    static let presets: [LLMProvider] = [
        LLMProvider(id: "ollama", name: "Ollama (on this machine)",
                    endpoint: "http://localhost:11434/v1/chat/completions",
                    wire: .openai, needsKey: false, suggestedModel: "llama3.1",
                    keyURL: nil, isLocal: true),
        LLMProvider(id: "lmstudio", name: "LM Studio (on this machine)",
                    endpoint: "http://localhost:1234/v1/chat/completions",
                    wire: .openai, needsKey: false, suggestedModel: "",
                    keyURL: nil, isLocal: true),
        LLMProvider(id: "llamacpp", name: "llama.cpp server (on this machine)",
                    endpoint: "http://localhost:8080/v1/chat/completions",
                    wire: .openai, needsKey: false, suggestedModel: "",
                    keyURL: nil, isLocal: true),
        LLMProvider(id: "openrouter", name: "OpenRouter (many models, one key)",
                    endpoint: "https://openrouter.ai/api/v1/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "anthropic/claude-opus-4.5",
                    keyURL: "https://openrouter.ai/keys", isLocal: false),
        LLMProvider(id: "anthropic", name: "Anthropic",
                    endpoint: "https://api.anthropic.com/v1/messages",
                    wire: .anthropic, needsKey: true, suggestedModel: "claude-opus-5",
                    keyURL: "https://console.anthropic.com/settings/keys", isLocal: false),
        LLMProvider(id: "openai", name: "OpenAI",
                    endpoint: "https://api.openai.com/v1/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "gpt-4o",
                    keyURL: "https://platform.openai.com/api-keys", isLocal: false),
        LLMProvider(id: "glm", name: "GLM (Zhipu)",
                    endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "glm-4-plus",
                    keyURL: "https://open.bigmodel.cn", isLocal: false),
        LLMProvider(id: "deepseek", name: "DeepSeek",
                    endpoint: "https://api.deepseek.com/v1/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "deepseek-chat",
                    keyURL: "https://platform.deepseek.com", isLocal: false),
        LLMProvider(id: "groq", name: "Groq",
                    endpoint: "https://api.groq.com/openai/v1/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "",
                    keyURL: "https://console.groq.com/keys", isLocal: false),
        LLMProvider(id: "together", name: "Together",
                    endpoint: "https://api.together.xyz/v1/chat/completions",
                    wire: .openai, needsKey: true, suggestedModel: "",
                    keyURL: "https://api.together.xyz/settings/api-keys", isLocal: false),
        LLMProvider(id: "custom", name: "Anything else",
                    endpoint: "", wire: .openai, needsKey: false, suggestedModel: "",
                    keyURL: nil, isLocal: false),
    ]

    static func preset(id: String) -> LLMProvider? { presets.first { $0.id == id } }

    // MARK: - What is chosen

    static var chosenID: String {
        get { Settings.object(forKey: "cleanProvider") as? String ?? "ollama" }
        set { Settings.set(newValue, forKey: "cleanProvider") }
    }

    /// A custom endpoint and wire, used when "Anything else" is chosen and as
    /// an override for a preset whose address has moved.
    static var customEndpoint: String {
        get { Settings.object(forKey: "cleanEndpoint") as? String ?? "" }
        set { Settings.set(newValue, forKey: "cleanEndpoint") }
    }

    static var customWire: Wire {
        get { (Settings.object(forKey: "cleanWire") as? String).flatMap(Wire.init(rawValue:)) ?? .openai }
        set { Settings.set(newValue.rawValue, forKey: "cleanWire") }
    }

    static var model: String {
        get { Settings.object(forKey: "cleanModel") as? String ?? "" }
        set { Settings.set(newValue, forKey: "cleanModel") }
    }

    /// The provider in force, with any custom address applied.
    static var current: LLMProvider {
        guard var provider = preset(id: chosenID) else { return presets[0] }
        if provider.id == "custom" || !customEndpoint.isEmpty {
            provider = LLMProvider(
                id: provider.id, name: provider.name,
                endpoint: customEndpoint.isEmpty ? provider.endpoint : customEndpoint,
                wire: provider.id == "custom" ? customWire : provider.wire,
                needsKey: provider.id == "custom" ? !customEndpoint.contains("localhost") : provider.needsKey,
                suggestedModel: provider.suggestedModel,
                keyURL: provider.keyURL, isLocal: provider.isLocal)
        }
        return provider
    }

    /// The model to ask for, falling back to what the preset suggests.
    static var currentModel: String {
        model.isEmpty ? current.suggestedModel : model
    }

    var url: URL? { URL(string: endpoint) }

    /// Whether everything needed to make a request is present.
    static func isReady() -> (ok: Bool, missing: String?) {
        let provider = current
        guard provider.url != nil, !provider.endpoint.isEmpty else {
            return (false, "No address to send to. Settings › Clean sets one.")
        }
        if provider.needsKey, APICredentials.key(for: provider.id) == nil {
            return (false, "No key for \(provider.name). Settings › Clean adds one.")
        }
        if currentModel.isEmpty {
            return (false, "No model chosen. Settings › Clean sets one.")
        }
        return (true, nil)
    }

    // MARK: - Finding what is already running

    /// Asks each local preset whether it is there, so somebody running Ollama
    /// does not have to be told what port it uses.
    static func findLocal(session: URLSession = .shared,
                          completion: @escaping ([LLMProvider]) -> Void) {
        let candidates = presets.filter(\.isLocal)
        var found: [LLMProvider] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in candidates {
            guard let base = provider.url?.deletingLastPathComponent()
                .appendingPathComponent("models") else { continue }
            group.enter()
            var request = URLRequest(url: base)
            request.timeoutInterval = 2
            session.dataTask(with: request) { data, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data != nil else { return }
                lock.lock(); found.append(provider); lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            completion(found.sorted { $0.id < $1.id })
        }
    }

    /// The models a server says it has. Only asked of servers that offer the
    /// list, so a name can be picked rather than typed from memory.
    static func models(for provider: LLMProvider, session: URLSession = .shared,
                       completion: @escaping ([String]) -> Void) {
        guard provider.wire == .openai,
              let url = provider.url?.deletingLastPathComponent().appendingPathComponent("models")
        else { return completion([]) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let key = APICredentials.key(for: provider.id) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, _, _ in
            let names: [String] = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0?["data"] as? [[String: Any]] }?
                .compactMap { $0["id"] as? String } ?? []
            DispatchQueue.main.async { completion(names.sorted()) }
        }.resume()
    }
}
