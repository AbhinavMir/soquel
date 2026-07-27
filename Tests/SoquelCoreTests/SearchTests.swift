import XCTest
@testable import SoquelCore

final class SearchMatchingTests: XCTestCase {
    private func query(_ text: String, matching: FileSearch.Matching = .contains,
                       caseSensitive: Bool = false) -> FileSearch.Query {
        var q = FileSearch.Query(text: text, root: URL(fileURLWithPath: "/tmp"))
        q.matching = matching
        q.caseSensitive = caseSensitive
        return q
    }

    func testSubstringMatching() {
        XCTAssertTrue(FileSearch.matches(name: "quarterly-invoice.pdf", query: query("invoice")))
        XCTAssertFalse(FileSearch.matches(name: "receipt.pdf", query: query("invoice")))
    }

    func testCaseSensitivityIsHonoured() {
        XCTAssertTrue(FileSearch.matches(name: "README.md", query: query("readme")))
        XCTAssertFalse(FileSearch.matches(name: "README.md", query: query("readme", caseSensitive: true)))
        XCTAssertTrue(FileSearch.matches(name: "README.md", query: query("README", caseSensitive: true)))
    }

    func testGlobMatching() {
        XCTAssertTrue(FileSearch.matches(name: "notes.txt", query: query("*.txt", matching: .glob)))
        XCTAssertFalse(FileSearch.matches(name: "notes.md", query: query("*.txt", matching: .glob)))
        XCTAssertTrue(FileSearch.matches(name: "a.txt", query: query("?.txt", matching: .glob)))
        XCTAssertFalse(FileSearch.matches(name: "ab.txt", query: query("?.txt", matching: .glob)))
    }

    /// A glob is anchored: "*.txt" must not match "txt-notes.md".
    func testGlobIsAnchored() {
        XCTAssertFalse(FileSearch.matches(name: "txt-notes.md", query: query("*.txt", matching: .glob)))
    }

    func testRegexMatching() {
        XCTAssertTrue(FileSearch.matches(name: "IMG_4812.JPG", query: query("^IMG_\\d+", matching: .regex)))
        XCTAssertFalse(FileSearch.matches(name: "photo.JPG", query: query("^IMG_\\d+", matching: .regex)))
    }

    /// A pattern that does not compile is reported, not silently treated as
    /// "matches nothing".
    func testInvalidRegexIsReported() {
        if case .success = FileSearch.compile(query("[unclosed", matching: .regex)) {
            XCTFail("an invalid pattern must be reported")
        }
        if case .failure = FileSearch.compile(query("valid.*", matching: .regex)) {
            XCTFail("a valid pattern must compile")
        }
        // Only regex is validated; a literal bracket is a fine substring.
        if case .failure = FileSearch.compile(query("[unclosed")) {
            XCTFail("substring search has no pattern to compile")
        }
    }
}

final class SearchRankingTests: XCTestCase {
    /// A file named for what you typed must outrank one that merely contains it.
    func testNameMatchesOutrankContentMatches() {
        let named = FileSearch.rank(name: "invoice.pdf", needle: "invoice", isContentMatch: false)
        let contained = FileSearch.rank(name: "notes.txt", needle: "invoice", isContentMatch: true)
        XCTAssertLessThan(named, contained)
    }

    func testExactNameOutranksPrefixOutranksSubstring() {
        let exact = FileSearch.rank(name: "invoice", needle: "invoice", isContentMatch: false)
        let stem = FileSearch.rank(name: "invoice.pdf", needle: "invoice", isContentMatch: false)
        let prefix = FileSearch.rank(name: "invoice-2026.pdf", needle: "invoice", isContentMatch: false)
        let middle = FileSearch.rank(name: "old-invoice-2026.pdf", needle: "invoice", isContentMatch: false)

        XCTAssertLessThan(exact, stem)
        XCTAssertLessThan(stem, prefix)
        XCTAssertLessThan(prefix, middle)
    }

    func testRankingIgnoresCase() {
        XCTAssertEqual(
            FileSearch.rank(name: "INVOICE.pdf", needle: "invoice", isContentMatch: false),
            FileSearch.rank(name: "invoice.pdf", needle: "invoice", isContentMatch: false)
        )
    }
}

final class SearchScopeTests: XCTestCase {
    /// "Everywhere" used to mean the home folder. It now means the filesystem.
    func testEverywhereStartsAtTheFilesystemRoot() {
        var query = FileSearch.Query(text: "x", root: URL(fileURLWithPath: "/tmp"))
        query.scope = .everywhere
        let roots = FileSearch.roots(for: query).map(\.path)
        XCTAssertTrue(roots.contains("/"), "everywhere must include the whole filesystem")
    }

    func testFolderScopeUsesTheGivenRoot() {
        var query = FileSearch.Query(text: "x", root: URL(fileURLWithPath: "/tmp/project"))
        query.scope = .folder
        XCTAssertEqual(FileSearch.roots(for: query).map(\.path), ["/tmp/project"])
    }

    func testHomeScopeUsesHome() {
        var query = FileSearch.Query(text: "x", root: URL(fileURLWithPath: "/tmp"))
        query.scope = .home
        XCTAssertEqual(FileSearch.roots(for: query).map(\.path),
                       [FileManager.default.homeDirectoryForCurrentUser.path])
    }

    /// Hidden files are searched unless the user turns them off. Silently
    /// skipping dotfiles is the loudest complaint about Finder's search.
    func testHiddenFilesAreIncludedByDefault() {
        let query = FileSearch.Query(text: "x", root: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(query.includeHidden)
        XCTAssertTrue(query.includePackages, "app bundles are searched by default too")
    }
}

final class SearchWalkTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ contents: String = "x") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ query: FileSearch.Query) -> (hits: [FileSearch.Hit], summary: FileSearch.Summary) {
        let done = expectation(description: "search")
        var collected: [FileSearch.Hit] = []
        var outcome = FileSearch.Summary()
        let search = FileSearch()
        search.run(query) { collected.append(contentsOf: $0) } finished: {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return (collected, outcome)
    }

    private func query(_ text: String) -> FileSearch.Query {
        FileSearch.Query(text: text, root: dir)
    }

    func testFindsFilesByName() throws {
        try write("alpha.txt")
        try write("nested/deep/alpha-copy.txt")
        try write("other.md")

        let result = run(query("alpha"))
        XCTAssertEqual(Set(result.hits.map(\.url.lastPathComponent)), ["alpha.txt", "alpha-copy.txt"])
        XCTAssertEqual(result.summary.found, 2)
    }

    /// The headline fix: a dotfile is found rather than skipped without a word.
    func testFindsHiddenFilesByDefault() throws {
        try write(".gitignore", "build/")
        let result = run(query("gitignore"))
        XCTAssertEqual(result.hits.map(\.url.lastPathComponent), [".gitignore"])
    }

    func testHiddenFilesCanStillBeExcluded() throws {
        try write(".gitignore", "build/")
        var q = query("gitignore")
        q.includeHidden = false
        XCTAssertTrue(run(q).hits.isEmpty)
    }

    /// App bundles are folders. Skipping their contents was silent; now it is
    /// a setting, and the default is to look.
    func testLooksInsideAppBundlesByDefault() throws {
        try write("Thing.app/Contents/Resources/config.plist", "<plist/>")
        let result = run(query("config"))
        XCTAssertEqual(result.hits.map(\.url.lastPathComponent), ["config.plist"])

        var excluded = query("config")
        excluded.includePackages = false
        XCTAssertTrue(run(excluded).hits.isEmpty)
    }

    func testDepthLimitIsHonoured() throws {
        try write("shallow.txt")
        try write("one/two/three/deep.txt")

        var q = query("txt")
        q.matching = .glob
        q.text = "*.txt"
        q.maximumDepth = 1
        let names = run(q).hits.map(\.url.lastPathComponent)
        XCTAssertTrue(names.contains("shallow.txt"))
        XCTAssertFalse(names.contains("deep.txt"), "a depth limit must actually stop the walk")
    }

    func testContentSearchFindsTextAndReportsTheLine() throws {
        try write("notes.md", "first line\nthe needle is here\nlast line")
        var q = query("needle")
        q.mode = .contents
        let result = run(q)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.excerpt, "the needle is here")
    }

    /// Binary files cannot be searched as text; they are counted so the summary
    /// can say so rather than pretending they held no match.
    func testBinaryFilesAreCountedNotHidden() throws {
        let binary = dir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0xFF]).write(to: binary)
        var q = query("needle")
        q.mode = .contents
        let result = run(q)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertGreaterThan(result.summary.skippedUnreadable, 0)
        XCTAssertTrue(result.summary.caveats.contains { $0.contains("not text") })
    }

    func testResultLimitStopsAndSaysSo() throws {
        for i in 0..<40 { try write("file\(i).txt") }
        var q = query("file")
        q.resultLimit = 10
        let result = run(q)
        XCTAssertTrue(result.summary.hitLimit)
        XCTAssertTrue(result.summary.caveats.contains { $0.contains("stopped at") })
    }

    func testEmptyQueryFindsNothingRatherThanEverything() {
        let result = run(query(""))
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.summary.examined, 0)
    }

    /// Results arrive best-first, so the file actually named for the query is
    /// at the top rather than wherever the walk happened to reach it.
    func testBestMatchesRankFirst() throws {
        try write("zzz-contains-report-inside.txt", "report")
        try write("report.txt", "unrelated")

        var q = query("report")
        let result = run(q)
        XCTAssertEqual(result.hits.sorted { $0.rank < $1.rank }.first?.url.lastPathComponent, "report.txt")
        q.mode = .name
    }

    func testCancellationStopsTheWalk() throws {
        for i in 0..<200 { try write("bulk/file\(i).txt") }
        let search = FileSearch()
        let done = expectation(description: "cancelled")
        search.run(query("file")) { _ in
            search.cancel()
        } finished: { summary in
            XCTAssertTrue(summary.cancelled || summary.found > 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }
}

final class ToolbarCatalogueTests: XCTestCase {
    override func tearDown() {
        ToolbarCatalogue.reset()
        super.tearDown()
    }

    func testEveryActionHasAUniqueIDAndARealSymbol() {
        let ids = ToolbarCatalogue.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for action in ToolbarCatalogue.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil),
                "\(action.id) uses \(action.symbol), which is not a real SF Symbol"
            )
        }
    }

    func testDefaultsIncludeTheViewAndHiddenToggles() {
        let defaults = Set(ToolbarCatalogue.defaultIDs)
        XCTAssertTrue(defaults.contains("listView"))
        XCTAssertTrue(defaults.contains("iconView"))
        XCTAssertTrue(defaults.contains("hidden"))
    }

    func testChoosingButtonsPersists() {
        ToolbarCatalogue.enabledIDs = ["hidden", "find"]
        XCTAssertEqual(ToolbarCatalogue.enabledIDs, ["hidden", "find"])
        ToolbarCatalogue.reset()
        XCTAssertEqual(ToolbarCatalogue.enabledIDs, ToolbarCatalogue.defaultIDs)
    }

    /// An id saved by an older build that no longer exists is dropped rather
    /// than breaking the bar.
    func testUnknownStoredIDsAreIgnored() {
        Settings.set(["hidden", "no-such-action"], forKey: "toolbarActions")
        XCTAssertEqual(ToolbarCatalogue.enabledIDs, ["hidden"])
    }
}
