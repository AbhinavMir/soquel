import XCTest
@testable import SoquelCore

/// Regressions in the search engine's account of itself: what it says about a
/// query it never ran, how deep the walk really went, and how many times
/// "everywhere" visits the same volume.
final class SweepSearchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sweep-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ path: String, _ contents: String = "x") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ query: FileSearch.Query) throws -> (hits: [FileSearch.Hit], summary: FileSearch.Summary) {
        let engine = FileSearch()
        var hits: [FileSearch.Hit] = []
        var outcome: FileSearch.Summary?
        let done = expectation(description: "search finished")
        engine.run(query, batch: { hits.append(contentsOf: $0) },
                   finished: { outcome = $0; done.fulfill() })
        wait(for: [done], timeout: 20)
        return (hits, try XCTUnwrap(outcome))
    }

    private func glob(_ pattern: String) -> FileSearch.Query {
        var query = FileSearch.Query(text: pattern, root: dir)
        query.matching = .glob
        return query
    }

    // MARK: - A pattern that does not compile

    /// A broken pattern used to finish with an untouched Summary, which the
    /// panel prints as "No matches in 0 items" — word for word what it says
    /// about a search that ran and found nothing.
    func testAnInvalidPatternIsReportedRatherThanReadAsNoMatches() throws {
        try write("alpha.txt")
        var query = FileSearch.Query(text: "[unclosed", root: dir)
        query.matching = .regex

        let result = try run(query)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.summary.found, 0)
        XCTAssertTrue(result.summary.caveats.contains { $0.contains("pattern error") },
                      "the summary said nothing about the pattern: \(result.summary.caveats)")
    }

    /// `run` must reject exactly what `compile` rejects, so the panel's
    /// pre-flight check and a search started anywhere else agree.
    func testRunRejectsWhatCompileRejects() throws {
        var query = FileSearch.Query(text: "(unbalanced", root: dir)
        query.matching = .regex
        if case .success = FileSearch.compile(query) {
            XCTFail("an unbalanced group must fail to compile")
        }
        XCTAssertTrue(try run(query).summary.caveats.contains { $0.contains("pattern error") })
    }

    /// The failure path must not swallow working patterns with it.
    func testAValidPatternStillSearchesAndSaysNothingExtra() throws {
        try write("IMG_4812.JPG")
        try write("photo.jpg")
        var query = FileSearch.Query(text: "^IMG_\\d+", root: dir)
        query.matching = .regex

        let result = try run(query)
        XCTAssertEqual(result.hits.map(\.url.lastPathComponent), ["IMG_4812.JPG"])
        XCTAssertTrue(result.summary.notes.isEmpty)
    }

    /// A glob is translated into a regular expression, so it goes through the
    /// same build and must survive it.
    func testGlobsStillCompile() throws {
        try write("notes.txt")
        let result = try run(glob("*.txt"))
        XCTAssertEqual(result.hits.map(\.url.lastPathComponent), ["notes.txt"])
        XCTAssertTrue(result.summary.notes.isEmpty)
    }

    // MARK: - Depth

    /// The limit used to be applied one level too late: every entry a level
    /// below it was enumerated, stat'd and added to `examined`, and only its
    /// descendants were pruned. `examined` is the denominator the panel prints
    /// as the scope of the search, so it covered a level nothing had looked at.
    func testDepthLimitDoesNotEnumerateTheLevelBelowIt() throws {
        try write("top.txt")
        for index in 0..<20 { try write("branch/leaf\(index).txt") }
        for index in 0..<20 { try write("other/leaf\(index).txt") }

        var query = glob("*")
        query.maximumDepth = 1

        let result = try run(query)
        XCTAssertEqual(Set(result.hits.map(\.url.lastPathComponent)), ["top.txt", "branch", "other"])
        XCTAssertEqual(result.summary.examined, 3,
                       "examined must count what was searched, not what was thrown away unsearched")
    }

    /// The other half of the same rule: the level the limit allows is still
    /// walked in full.
    func testDepthLimitStillReachesTheLevelItAllows() throws {
        try write("branch/leaf.txt")
        try write("branch/deeper/buried.txt")

        var query = glob("*.txt")
        query.maximumDepth = 2

        let names = Set(try run(query).hits.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("leaf.txt"))
        XCTAssertFalse(names.contains("buried.txt"))
    }

    /// Without a limit nothing is pruned, so the deep file is still found.
    func testNoDepthLimitWalksTheWholeTree() throws {
        try write("branch/deeper/buried.txt")
        let names = try run(glob("buried*")).hits.map(\.url.lastPathComponent)
        XCTAssertEqual(names, ["buried.txt"])
    }

    /// A path an ignore file excluded has its own line in the summary, so
    /// counting it in `examined` as well claims a search of something that was
    /// deliberately skipped.
    func testIgnoredPathsAreNotCountedAsExamined() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try write(".gitignore", "junk\n")
        try write("keep.txt")
        try write("junk/dropped.txt")

        var query = glob("*")
        let walked = try run(query).summary
        query.respectGitignore = true
        let honoured = try run(query).summary

        XCTAssertGreaterThan(honoured.skippedIgnored, 0)
        XCTAssertLessThan(honoured.examined, walked.examined)
        // Only ".gitignore" and "keep.txt" are left, and "*" matches both.
        XCTAssertEqual(honoured.examined, 2)
        XCTAssertEqual(honoured.found, honoured.examined)
    }
}

/// Which trees "everywhere" walks, and how many times it walks each of them.
final class SweepSearchScopeTests: XCTestCase {
    private func query(_ scope: FileSearch.Scope) -> FileSearch.Query {
        var q = FileSearch.Query(text: "x", root: URL(fileURLWithPath: "/tmp"))
        q.scope = scope
        return q
    }

    /// Volumes mount under "/" and the enumerator crosses mount points, so
    /// adding them as extra roots walked every attached drive twice: each hit
    /// on it appeared twice, `examined` counted it twice, and the result limit
    /// was reached halfway through the filesystem while the summary reported
    /// the cap as if it were the whole picture.
    func testEverywhereIsASingleWalkOfTheFilesystem() {
        XCTAssertEqual(FileSearch.roots(for: query(.everywhere)).map(\.path), ["/"])
    }

    /// The general form of the same rule, for every scope: no root may sit
    /// inside another root, because the walk would cover it twice.
    func testNoRootSitsInsideAnother() {
        for scope in FileSearch.Scope.allCases {
            let roots = FileSearch.roots(for: query(scope)).map(\.standardizedFileURL.path)
            for (index, root) in roots.enumerated() {
                for (otherIndex, other) in roots.enumerated() where otherIndex != index {
                    let prefix = other.hasSuffix("/") ? other : other + "/"
                    XCTAssertFalse(root == other || root.hasPrefix(prefix),
                                   "\(scope.title): \(root) is walked again under \(other)")
                }
            }
        }
    }
}
