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
        XCTAssertFalse(APICredentials.looksLikeAKey("hello"))
        XCTAssertFalse(APICredentials.looksLikeAKey("sk-ant-"))
        XCTAssertTrue(APICredentials.looksLikeAKey("sk-ant-api03-abcdefghijklmnop"))
    }

    /// The request has to be the shape the API expects.
    func testTheRequestIsWellFormed() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("hello", "a.txt", in: folder)
        let body = CleanFolder.requestBody(for: folder, payload: CleanSanitiser.gather(folder))
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertNotNil(body["max_tokens"])
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNil(body["budget_tokens"], "budget_tokens is rejected on this model")
        let choice = body["tool_choice"] as? [String: Any]
        XCTAssertEqual(choice?["name"] as? String, "propose_structure")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: body))
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
