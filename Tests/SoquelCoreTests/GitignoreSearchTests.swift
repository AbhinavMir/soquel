import XCTest
@testable import SoquelCore

/// The search engine honouring .gitignore, end to end.
final class GitignoreSearchTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-search-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try "node_modules\n*.log\n".write(
            to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        try write("needle here", "src/found.txt")
        try write("needle here", "run.log")
        try write("needle here", "node_modules/pkg/found.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, _ path: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func search(_ query: FileSearch.Query) throws -> ([FileSearch.Hit], FileSearch.Summary) {
        let engine = FileSearch()
        var hits: [FileSearch.Hit] = []
        var summary: FileSearch.Summary?
        let done = expectation(description: "search finished")
        engine.run(query, batch: { hits.append(contentsOf: $0) }, finished: { summary = $0; done.fulfill() })
        wait(for: [done], timeout: 20)
        return (hits, try XCTUnwrap(summary))
    }

    func testIgnoredFilesAreFoundWhenTheOptionIsOff() throws {
        var query = FileSearch.Query(text: "found", root: repo)
        query.respectGitignore = false
        let (hits, summary) = try search(query)
        let names = Set(hits.map { $0.url.lastPathComponent })
        XCTAssertTrue(names.contains("found.txt"))
        XCTAssertTrue(hits.contains { $0.url.path.contains("node_modules") })
        XCTAssertEqual(summary.skippedIgnored, 0)
    }

    func testIgnoredFoldersAreSkippedWhenTheOptionIsOn() throws {
        var query = FileSearch.Query(text: "found", root: repo)
        query.respectGitignore = true
        let (hits, summary) = try search(query)
        XCTAssertFalse(hits.contains { $0.url.path.contains("node_modules") })
        XCTAssertTrue(hits.contains { $0.url.path.contains("src/found.txt") })
        XCTAssertGreaterThan(summary.skippedIgnored, 0)
    }

    /// Skipping must be reported, not silent — that is the rule the whole
    /// search engine is built around.
    func testTheSummarySaysWhatWasIgnored() throws {
        var query = FileSearch.Query(text: "run", root: repo)
        query.respectGitignore = true
        let (_, summary) = try search(query)
        XCTAssertTrue(summary.caveats.contains { $0.contains(".gitignore") })
    }

    func testContentsSearchAlsoHonoursIgnoreFiles() throws {
        var query = FileSearch.Query(text: "needle", root: repo)
        query.mode = .contents
        query.respectGitignore = true
        let (hits, _) = try search(query)
        XCTAssertFalse(hits.contains { $0.url.path.contains("node_modules") })
        XCTAssertFalse(hits.contains { $0.url.lastPathComponent == "run.log" })
        XCTAssertTrue(hits.contains { $0.url.lastPathComponent == "found.txt" })
    }

    func testTheGitDirectoryIsNeverWalkedWhenHonouringIgnoreFiles() throws {
        try write("needle", ".git/config-ish.txt")
        var query = FileSearch.Query(text: "config-ish", root: repo)
        query.respectGitignore = true
        let (hits, _) = try search(query)
        XCTAssertTrue(hits.isEmpty)
    }
}
