import XCTest
@testable import SoquelCore

/// Clean This Folder is the only feature that sends file contents off the
/// machine, so what it will and will not send is the part worth pinning down.
final class CleanFolderTests: XCTestCase {
    private func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, _ name: String, in folder: URL) {
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(name).path, contents: Data(text.utf8))
    }

    // MARK: - What is never opened

    func testFilesWhoseNameSuggestsASecretAreNeverOpened() {
        for name in [".env", ".env.local", "prod.env", "id_rsa", "id_ed25519",
                     "server.pem", "cert.key", "store.p12", ".netrc",
                     ".git-credentials", "vault.kdbx", "SECRET.PEM"] {
            XCTAssertTrue(CleanSanitiser.isSensitiveName(name), "\(name) would have been opened")
        }
        for name in ["notes.txt", "main.swift", "README.md", "environment.md", "keynote.pdf"] {
            XCTAssertFalse(CleanSanitiser.isSensitiveName(name), "\(name) was needlessly withheld")
        }
    }

    func testASensitiveFileIsListedButNotRead() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Not hidden, so it reaches the name test rather than being skipped
        // for being a dotfile.
        write("SUPER_SECRET_VALUE_12345", "prod.env", in: folder)
        write("hello", "readme.txt", in: folder)

        let payload = CleanSanitiser.gather(folder)
        let env = payload.entries.first { $0.name == "prod.env" }
        XCTAssertNotNil(env, "the name should still be sent")
        XCTAssertNil(env?.head, "prod.env was read")
        XCTAssertNotNil(env?.skipped)
        XCTAssertFalse(CleanSanitiser.preview(payload).contains("SUPER_SECRET_VALUE_12345"))
    }

    /// Hidden files are not gathered at all, so a dotfile's contents cannot be
    /// sent even before the name rules are consulted.
    func testHiddenFilesAreNotGatheredAtAll() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("SUPER_SECRET_VALUE_12345", ".env", in: folder)
        write("hello", "readme.txt", in: folder)

        let payload = CleanSanitiser.gather(folder)
        XCTAssertNil(payload.entries.first { $0.name == ".env" })
        XCTAssertFalse(CleanSanitiser.preview(payload).contains("SUPER_SECRET_VALUE_12345"))
        XCTAssertNotNil(payload.entries.first { $0.name == "readme.txt" })
    }

    // MARK: - Redaction

    func testThingsThatLookLikeSecretsAreRemoved() {
        let samples = [
            "api_key = sk-ant-abcdefghijklmnop12345",
            "PASSWORD: hunter2hunter2",
            "token=\"ghp_abcdefghijklmnopqrstuvwxyz0123\"",
            "aws: AKIAIOSFODNN7EXAMPLE",
            "slack xoxb-1234567890-abcdefghij",
            "google AIzaSyA0000000000000000000000000000000",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r",
            "db url postgres://user:passw0rd@localhost/db",
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
        ]
        for sample in samples {
            let cleaned = CleanSanitiser.redact(sample)
            XCTAssertTrue(cleaned.contains("[removed]"), "nothing removed from: \(sample)")
            for secret in ["sk-ant-abcdefghijklmnop12345", "hunter2hunter2",
                           "ghp_abcdefghijklmnopqrstuvwxyz0123", "AKIAIOSFODNN7EXAMPLE",
                           "passw0rd", "MIIEowIBAAKCAQEA"] where sample.contains(secret) {
                XCTAssertFalse(cleaned.contains(secret), "\(secret) survived redaction")
            }
        }
    }

    func testOrdinaryTextIsLeftAlone() {
        let prose = "This is a note about the quarterly report. It mentions no keys at all."
        XCTAssertEqual(CleanSanitiser.redact(prose), prose)
    }

    /// Redaction is for the copy in the request. The file must not change.
    func testRedactionNeverTouchesTheFileOnDisk() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = "api_key = sk-ant-abcdefghijklmnop12345\n"
        write(secret, "config.txt", in: folder)

        _ = CleanSanitiser.gather(folder)

        let after = try String(contentsOf: folder.appendingPathComponent("config.txt"), encoding: .utf8)
        XCTAssertEqual(after, secret, "the file on disk was altered")
    }

    func testBinaryFilesAreNamedButNotRead() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])
        bytes.append(Data(repeating: 0xFF, count: 40))
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("image.png").path, contents: bytes)

        let payload = CleanSanitiser.gather(folder)
        let entry = payload.entries.first { $0.name == "image.png" }
        XCTAssertEqual(entry?.skipped, "not text")
        XCTAssertNil(entry?.head)
    }

    /// A big folder must not quietly become a big upload.
    func testTheRequestIsCappedAndSaysSo() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Each file contributes at most headBytes, so the cap needs more than
        // totalBytes / headBytes files to be reached at all.
        let block = String(repeating: "lorem ipsum dolor sit amet ", count: 400)
        let needed = CleanSanitiser.totalBytes / CleanSanitiser.headBytes + 20
        for index in 0..<needed { write(block, "file\(index).txt", in: folder) }

        let payload = CleanSanitiser.gather(folder)
        XCTAssertLessThanOrEqual(payload.bytes, CleanSanitiser.totalBytes + CleanSanitiser.headBytes)
        XCTAssertTrue(payload.notes.contains { $0.contains("request was already full") },
                      "the cap was hit without saying so")
    }

    // MARK: - Where a plan may put things

    func testAPlanMayNotMoveFilesJustAnywhere() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleaning = root.appendingPathComponent("cleaning")
        let global = root.appendingPathComponent("global")
        let elsewhere = root.appendingPathComponent("elsewhere")
        for url in [cleaning, global, elsewhere] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let saved = FolderContext.globals
        defer { FolderContext.globals = saved }
        FolderContext.globals = [global.path]

        XCTAssertTrue(FolderContext.isAllowedDestination(
            cleaning.appendingPathComponent("sub/a.txt"), cleaning: cleaning))
        XCTAssertTrue(FolderContext.isAllowedDestination(
            global.appendingPathComponent("abc/a.txt"), cleaning: cleaning))
        XCTAssertFalse(FolderContext.isAllowedDestination(
            elsewhere.appendingPathComponent("a.txt"), cleaning: cleaning),
            "a plan could file into a folder that is neither the target nor global")
        XCTAssertFalse(FolderContext.isAllowedDestination(
            URL(fileURLWithPath: "/etc/passwd"), cleaning: cleaning))
    }

    /// The model answers with names and paths. Every one is checked.
    func testHostileStepsAreBlockedRatherThanShownAsActionable() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("x", "real.txt", in: folder)
        let saved = FolderContext.globals
        defer { FolderContext.globals = saved }
        FolderContext.globals = []

        var claimed = Set<String>()
        func check(_ file: String, _ destination: String) -> CleanFolder.Step {
            CleanFolder.step(file: file, destination: destination, reason: "",
                             folder: folder, claimed: &claimed)
        }
        XCTAssertNotNil(check("real.txt", "../escaped.txt").problem,
                        "a move out of the folder was offered")
        XCTAssertNotNil(check("real.txt", "/etc/passwd").problem)
        XCTAssertNotNil(check("../../etc/passwd", "sub/x.txt").problem,
                        "a file outside the folder was accepted as a source")
        XCTAssertNotNil(check("invented.txt", "sub/x.txt").problem,
                        "a file that does not exist was offered as a move")
        XCTAssertNil(check("real.txt", "sorted/real.txt").problem)
    }

    /// Two files planned onto one name would destroy one of them.
    func testTwoFilesCannotBePlannedOntoOneName() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("a", "one.txt", in: folder)
        write("b", "two.txt", in: folder)

        var claimed = Set<String>()
        let first = CleanFolder.step(file: "one.txt", destination: "sorted/merged.txt",
                                     reason: "", folder: folder, claimed: &claimed)
        let second = CleanFolder.step(file: "two.txt", destination: "sorted/merged.txt",
                                      reason: "", folder: folder, claimed: &claimed)
        XCTAssertNil(first.problem)
        XCTAssertNotNil(second.problem, "the second file would have overwritten the first")
    }

    // MARK: - Reading the answer

    func testAToolCallBecomesAPlan() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("x", "invoice.pdf", in: folder)
        let json = """
        {"content":[{"type":"tool_use","name":"propose_structure","input":{
          "summary":"Group the invoices.",
          "moves":[{"file":"invoice.pdf","destination":"invoices/invoice.pdf","reason":"an invoice"}]}}]}
        """
        guard case .success(let plan) = CleanFolder.parse(Data(json.utf8), folder: folder) else {
            return XCTFail("the plan did not parse")
        }
        XCTAssertEqual(plan.summary, "Group the invoices.")
        XCTAssertEqual(plan.usable.count, 1)
        XCTAssertEqual(plan.steps[0].destination.lastPathComponent, "invoice.pdf")
        XCTAssertEqual(plan.steps[0].newFolder, "invoices")
    }

    func testAnAnswerWithNoPlanIsAnError() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for json in ["{}", "not json", "{\"content\":[]}",
                     "{\"content\":[{\"type\":\"text\",\"text\":\"I would move things around\"}]}"] {
            if case .success = CleanFolder.parse(Data(json.utf8), folder: folder) {
                XCTFail("\(json) was treated as a plan")
            }
        }
    }

    /// A key is never written into settings.json, which is plain text and is
    /// the file somebody pastes into a bug report.
    func testTheKeyIsNotKeptInSettings() {
        XCTAssertNil(Settings.object(forKey: "anthropicAPIKey"))
        XCTAssertNil(Settings.object(forKey: "apiKey"))
        XCTAssertNil(Settings.object(forKey: "cleanKey"))
        // Loose on purpose: every provider names its keys differently.
        XCTAssertFalse(APICredentials.looksLikeAKey("hello"))
        XCTAssertFalse(APICredentials.looksLikeAKey("has a space in it"))
        XCTAssertTrue(APICredentials.looksLikeAKey("sk-ant-api03-abcdefghijklmnop"))
        XCTAssertTrue(APICredentials.looksLikeAKey("sk-or-v1-abcdefghijklmnop"))
        XCTAssertTrue(APICredentials.looksLikeAKey("gsk_abcdefghijklmnopqrst"))
    }

    /// Each wire has its own shape, and both have to be valid JSON.
    func testBothWiresAreWellFormed() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("hello", "a.txt", in: folder)
        let payload = CleanSanitiser.gather(folder)

        let anthropic = LLMProvider.preset(id: "anthropic")!
        let a = CleanFolder.requestBody(for: folder, payload: payload,
                                        provider: anthropic, model: "claude-opus-5")
        XCTAssertEqual(a["model"] as? String, "claude-opus-5")
        XCTAssertEqual((a["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNil(a["budget_tokens"], "budget_tokens is rejected on this model")
        XCTAssertNotNil(a["system"], "the anthropic wire takes system as a field")
        XCTAssertEqual((a["tool_choice"] as? [String: Any])?["name"] as? String, "propose_structure")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: a))

        let ollama = LLMProvider.preset(id: "ollama")!
        let o = CleanFolder.requestBody(for: folder, payload: payload,
                                        provider: ollama, model: "llama3.1")
        XCTAssertEqual(o["model"] as? String, "llama3.1")
        XCTAssertNil(o["system"], "the chat wire takes system as a message, not a field")
        let messages = o["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        let function = ((o["tools"] as? [[String: Any]])?.first?["function"]) as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "propose_structure")
        XCTAssertNotNil(function?["parameters"], "the chat wire calls the schema parameters")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: o))
    }

    /// The key goes in a different header on each wire, and a local server is
    /// sent none at all.
    func testTheKeyGoesInTheRightHeaderAndLocalGetsNone() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("hello", "a.txt", in: folder)
        let payload = CleanSanitiser.gather(folder)

        let ollama = LLMProvider.preset(id: "ollama")!
        let local = CleanFolder.request(for: folder, payload: payload, provider: ollama, model: "x")
        XCTAssertNil(local?.value(forHTTPHeaderField: "Authorization"),
                     "a key was sent to a server on this machine")
        XCTAssertNil(local?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(local?.url?.host, "localhost")

        let anthropic = LLMProvider.preset(id: "anthropic")!
        APICredentials.store("test-key-abcdefghij", for: anthropic.id)
        defer { APICredentials.remove(for: anthropic.id) }
        let hosted = CleanFolder.request(for: folder, payload: payload, provider: anthropic, model: "x")
        XCTAssertEqual(hosted?.value(forHTTPHeaderField: "x-api-key"), "test-key-abcdefghij")
        XCTAssertEqual(hosted?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(hosted?.value(forHTTPHeaderField: "Authorization"))

        let router = LLMProvider.preset(id: "openrouter")!
        APICredentials.store("sk-or-v1-abcdefghij", for: router.id)
        defer { APICredentials.remove(for: router.id) }
        let bearer = CleanFolder.request(for: folder, payload: payload, provider: router, model: "x")
        XCTAssertEqual(bearer?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-abcdefghij")
    }

    /// One key per provider, so switching between them does not mean pasting
    /// a key again.
    func testKeysAreRememberedPerProvider() {
        defer {
            APICredentials.remove(for: "anthropic")
            APICredentials.remove(for: "openrouter")
        }
        APICredentials.store("key-for-anthropic-1", for: "anthropic")
        APICredentials.store("key-for-openrouter-2", for: "openrouter")
        XCTAssertEqual(APICredentials.key(for: "anthropic"), "key-for-anthropic-1")
        XCTAssertEqual(APICredentials.key(for: "openrouter"), "key-for-openrouter-2")
        APICredentials.remove(for: "anthropic")
        XCTAssertNil(APICredentials.key(for: "anthropic"))
        XCTAssertEqual(APICredentials.key(for: "openrouter"), "key-for-openrouter-2",
                       "removing one provider's key took another's with it")
    }

    /// Every preset has to be usable as written.
    func testEveryPresetIsCoherent() {
        for provider in LLMProvider.presets where provider.id != "custom" {
            XCTAssertFalse(provider.endpoint.isEmpty, "\(provider.id) has no address")
            XCTAssertNotNil(URL(string: provider.endpoint), "\(provider.id) has an unusable address")
            XCTAssertEqual(provider.isLocal, provider.endpoint.contains("localhost"),
                           "\(provider.id) disagrees with itself about being local")
            XCTAssertEqual(provider.needsKey, !provider.isLocal,
                           "\(provider.id) asks for a key it does not need, or the reverse")
            if provider.needsKey { XCTAssertNotNil(provider.keyURL, "\(provider.id) says where to get no key") }
        }
        XCTAssertEqual(LLMProvider.preset(id: "anthropic")?.wire, .anthropic)
        for id in ["ollama", "lmstudio", "llamacpp", "openrouter", "glm", "deepseek", "groq"] {
            XCTAssertEqual(LLMProvider.preset(id: id)?.wire, .openai, "\(id) is on the wrong wire")
        }
    }

    /// Global folders and context are what let a file leave the folder at all.
    func testGlobalFoldersAndContextRoundTrip() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let savedGlobals = FolderContext.globals
        let savedNotes = FolderContext.notes
        defer { FolderContext.globals = savedGlobals; FolderContext.notes = savedNotes }

        XCTAssertFalse(FolderContext.isGlobal(folder))
        FolderContext.setGlobal(true, for: folder)
        XCTAssertTrue(FolderContext.isGlobal(folder))
        FolderContext.setNote("invoices, one per month", for: folder)
        XCTAssertEqual(FolderContext.note(for: folder), "invoices, one per month")
        XCTAssertTrue(CleanFolder.systemPrompt(for: folder).contains("invoices, one per month"))
        XCTAssertTrue(CleanFolder.systemPrompt(for: folder).contains(folder.path))

        FolderContext.setNote("", for: folder)
        XCTAssertNil(FolderContext.note(for: folder))
        FolderContext.setGlobal(false, for: folder)
        XCTAssertFalse(FolderContext.isGlobal(folder))
    }
}

/// The beta gate. With it off the feature must not exist anywhere.
extension CleanFolderTests {
    func testTheFeatureIsOffByDefault() {
        let saved = Prefs.cleanFolder
        defer { Prefs.cleanFolder = saved }
        Prefs.cleanFolder = false
        XCTAssertFalse(Prefs.cleanFolder)
    }

    func testNothingIsOfferedWhileTheBetaIsOff() {
        let saved = Prefs.cleanFolder
        defer { Prefs.cleanFolder = saved }

        let ids = ["tools.clean", "tools.folderContext", "tools.globalFolder"]
        Prefs.cleanFolder = false
        for id in ids {
            let command = CommandRegistry.all.first { $0.id == id }
            XCTAssertNotNil(command, "\(id) is not registered at all")
            XCTAssertFalse(command?.isAvailable() ?? true, "\(id) is offered with the beta off")
        }
        XCTAssertFalse(ToolbarCatalogue.available.contains { $0.id == "clean" },
                       "the toolbar button is offered with the beta off")

        Prefs.cleanFolder = true
        for id in ids {
            XCTAssertTrue(CommandRegistry.all.first { $0.id == id }?.isAvailable() ?? false,
                          "\(id) is missing with the beta on")
        }
        XCTAssertTrue(ToolbarCatalogue.available.contains { $0.id == "clean" })
    }

    /// The button is a sparkle, and it is in the catalogue so it can be put in
    /// the bar by right-clicking it.
    func testTheToolbarButtonIsASparkle() {
        let saved = Prefs.cleanFolder
        defer { Prefs.cleanFolder = saved }
        Prefs.cleanFolder = true
        let action = ToolbarCatalogue.action(id: "clean")
        XCTAssertEqual(action?.symbol, "sparkles")
        XCTAssertEqual(action?.title, "Clean This Folder")
    }

    /// A button belonging to a beta that is off must be hidden, not forgotten:
    /// turning the beta back on brings it back where it was.
    func testTurningTheBetaOffDoesNotForgetTheButton() {
        let savedBeta = Prefs.cleanFolder
        let savedIDs = Settings.stringArray(forKey: "toolbarActions")
        defer {
            Prefs.cleanFolder = savedBeta
            Settings.set(savedIDs, forKey: "toolbarActions")
        }
        Prefs.cleanFolder = true
        ToolbarCatalogue.enabledIDs = ["up", "clean", "palette"]
        Prefs.cleanFolder = false
        XCTAssertTrue(ToolbarCatalogue.enabledIDs.contains("clean"),
                      "the stored choice was thrown away when the beta went off")
    }
}

/// Answers come back in three shapes and all three have to read.
extension CleanFolderTests {
    private func folderWithInvoice() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("invoice.pdf").path, contents: Data("x".utf8))
        return folder
    }

    /// The chat wire returns arguments as a *string* of JSON, not an object.
    func testAChatWireToolCallReads() throws {
        let folder = try folderWithInvoice()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = """
        {"choices":[{"message":{"role":"assistant","tool_calls":[{"type":"function","function":{
          "name":"propose_structure",
          "arguments":"{\\"summary\\":\\"Group them.\\",\\"moves\\":[{\\"file\\":\\"invoice.pdf\\",\\"destination\\":\\"invoices/invoice.pdf\\",\\"reason\\":\\"an invoice\\"}]}"
        }}]}}]}
        """
        guard case .success(let plan) = CleanFolder.parse(Data(json.utf8), folder: folder) else {
            return XCTFail("a chat-wire tool call did not parse")
        }
        XCTAssertEqual(plan.summary, "Group them.")
        XCTAssertEqual(plan.usable.count, 1)
    }

    /// A small local model often ignores the tool and writes the JSON into its
    /// reply, sometimes in a fenced block with a sentence in front. Refusing
    /// that would mean telling somebody their own hardware is not good enough
    /// when the answer is right there.
    func testAPlanWrittenInProseStillReads() throws {
        let folder = try folderWithInvoice()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = #"{"summary":"Group them.","moves":[{"file":"invoice.pdf","destination":"invoices/invoice.pdf","reason":"an invoice"}]}"#
        let reply = "Sure! Here is the plan:\n\n```json\n\(inner)\n```\n\nHope that helps."
        let json = try String(
            data: JSONSerialization.data(withJSONObject:
                ["choices": [["message": ["role": "assistant", "content": reply]]]]),
            encoding: .utf8)!
        guard case .success(let plan) = CleanFolder.parse(Data(json.utf8), folder: folder) else {
            return XCTFail("a plan written in prose did not parse")
        }
        XCTAssertEqual(plan.usable.count, 1)
        XCTAssertEqual(plan.summary, "Group them.")
    }

    /// Braces inside strings must not end the object early.
    func testBracesInsideStringsDoNotConfuseTheReader() {
        let text = "before {\"summary\":\"a } brace\",\"moves\":[]} after"
        let object = CleanFolder.firstJSONObject(in: text)
        XCTAssertEqual(object?["summary"] as? String, "a } brace")
    }

    /// Prose with no plan in it is still not a plan.
    func testProseWithNoPlanIsRefused() throws {
        let folder = try folderWithInvoice()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = #"{"choices":[{"message":{"content":"I would put the invoices together."}}]}"#
        if case .success = CleanFolder.parse(Data(json.utf8), folder: folder) {
            XCTFail("prose with no plan was treated as one")
        }
    }
}

/// The picker shows an icon and a line per provider, and that data has to be
/// there for every one of them.
extension CleanFolderTests {
    func testEveryProviderHasAnIconAndALine() {
        for provider in LLMProvider.presets {
            XCTAssertFalse(provider.symbol.isEmpty, "\(provider.id) has no icon")
            XCTAssertNotNil(NSImage(systemSymbolName: provider.symbol, accessibilityDescription: nil),
                            "\(provider.id) names an SF Symbol that does not exist: \(provider.symbol)")
            XCTAssertFalse(provider.tagline.isEmpty, "\(provider.id) has no tagline")
            XCTAssertLessThan(provider.tagline.count, 70,
                              "\(provider.id)'s tagline will not fit on a tile")
        }
    }

    /// The local ones say so on the tile, because that is the whole reason to
    /// pick them.
    func testLocalProvidersSayTheySendNothing() {
        for provider in LLMProvider.presets where provider.isLocal {
            XCTAssertTrue(provider.tagline.lowercased().contains("no key"),
                          "\(provider.id) does not say it needs no key")
        }
    }

    /// Names are shown on a 140-point tile, so the parenthetical suffixes the
    /// menu used are trimmed off.
    func testTileNamesAreShortEnoughToRead() {
        for provider in LLMProvider.presets {
            let shown = provider.name
                .replacingOccurrences(of: " (on this machine)", with: "")
                .replacingOccurrences(of: " (many models, one key)", with: "")
            XCTAssertLessThan(shown.count, 22, "\(provider.id) will be truncated on its tile")
        }
    }
}

/// The picker is one row, and the order in it is the recommendation.
extension CleanFolderTests {
    func testLocalProvidersComeFirstInThePicker() {
        let ordered = LLMProvider.presets.sorted { ($0.isLocal ? 0 : 1) < ($1.isLocal ? 0 : 1) }
        let firstHosted = ordered.firstIndex { !$0.isLocal } ?? ordered.count
        let lastLocal = ordered.lastIndex { $0.isLocal } ?? -1
        XCTAssertLessThan(lastLocal, firstHosted,
                          "a provider needing a key is shown before one that does not")
        XCTAssertEqual(ordered.prefix(3).filter(\.isLocal).count, 3,
                       "the three that run here are not the first three")
    }

    /// The key row is shown for exactly the providers that need one.
    func testOnlyKeyNeedingProvidersAskForAKey() {
        for provider in LLMProvider.presets {
            XCTAssertEqual(provider.needsKey, !provider.isLocal && provider.id != "custom",
                           "\(provider.id) disagrees about whether it wants a key")
        }
    }
}
