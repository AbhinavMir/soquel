import XCTest
@testable import SoquelCore

final class SavedSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.removeObject(forKey: "savedSearches")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-saved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Settings.removeObject(forKey: "savedSearches")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func sampleQuery() -> FileSearch.Query {
        var query = FileSearch.Query(text: "TODO", root: root)
        query.mode = .contents
        query.matching = .regex
        query.scope = .everywhere
        query.caseSensitive = true
        query.includeHidden = false
        query.includePackages = false
        query.respectGitignore = true
        query.maximumDepth = 3
        return query
    }

    /// A saved search must reopen exactly as it was saved, not as a text box
    /// with the words in it.
    func testEveryOptionSurvivesTheRoundTrip() {
        let saved = SavedSearch(name: "todos", query: sampleQuery())
        let restored = saved.query(fallbackRoot: root)

        XCTAssertEqual(restored.text, "TODO")
        XCTAssertEqual(restored.mode, .contents)
        XCTAssertEqual(restored.matching, .regex)
        XCTAssertEqual(restored.scope, .everywhere)
        XCTAssertTrue(restored.caseSensitive)
        XCTAssertFalse(restored.includeHidden)
        XCTAssertFalse(restored.includePackages)
        XCTAssertTrue(restored.respectGitignore)
        XCTAssertEqual(restored.maximumDepth, 3)
        XCTAssertEqual(restored.root.path, root.path)
    }

    func testSavingAndListing() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        XCTAssertEqual(SavedSearchStore.all.map(\.name), ["todos"])
    }

    /// Saving twice from the same panel should update, not accumulate
    /// near-duplicates.
    func testSavingTheSameNameReplacesAndKeepsTheIdentity() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        let originalID = SavedSearchStore.all[0].id

        var second = sampleQuery()
        second.text = "FIXME"
        SavedSearchStore.save(SavedSearch(name: "todos", query: second))

        XCTAssertEqual(SavedSearchStore.all.count, 1)
        XCTAssertEqual(SavedSearchStore.all[0].text, "FIXME")
        XCTAssertEqual(SavedSearchStore.all[0].id, originalID)
    }

    func testDifferentNamesCoexist() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        SavedSearchStore.save(SavedSearch(name: "fixmes", query: sampleQuery()))
        XCTAssertEqual(Set(SavedSearchStore.all.map(\.name)), ["todos", "fixmes"])
    }

    func testRenaming() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        let id = SavedSearchStore.all[0].id
        SavedSearchStore.rename(id: id, to: "outstanding")
        XCTAssertEqual(SavedSearchStore.all.map(\.name), ["outstanding"])
    }

    func testRemoving() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        SavedSearchStore.remove(id: SavedSearchStore.all[0].id)
        XCTAssertTrue(SavedSearchStore.all.isEmpty)
    }

    func testLookupByID() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        let id = SavedSearchStore.all[0].id
        XCTAssertEqual(SavedSearchStore.search(id: id)?.name, "todos")
        XCTAssertNil(SavedSearchStore.search(id: UUID()))
    }

    /// A renamed or deleted project must not turn a saved search into an error.
    func testAMissingRootFallsBackToTheCurrentFolder() throws {
        var query = sampleQuery()
        query.scope = .folder
        let saved = SavedSearch(name: "gone", query: query)
        try FileManager.default.removeItem(at: root)

        let fallback = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(saved.rootIsMissing)
        XCTAssertEqual(saved.query(fallbackRoot: fallback).root.path, fallback.path)
    }

    func testAPresentRootIsNotReportedMissing() {
        var query = sampleQuery()
        query.scope = .folder
        XCTAssertFalse(SavedSearch(name: "here", query: query).rootIsMissing)
    }

    /// Scopes that do not use a root must never be flagged as broken.
    func testAnEverywhereSearchIsNeverMissingItsRoot() throws {
        let saved = SavedSearch(name: "all", query: sampleQuery())
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(saved.rootIsMissing)
    }

    func testSubtitleDescribesTheSearch() {
        let saved = SavedSearch(name: "todos", query: sampleQuery())
        XCTAssertTrue(saved.subtitle.contains("contents"))
        XCTAssertTrue(saved.subtitle.contains("everywhere"))
        XCTAssertTrue(saved.subtitle.contains("git-aware"))
    }

    func testStoredAsReadableJSON() {
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        Settings.writeNow()
        let raw = Settings.object(forKey: "savedSearches") as? [[String: Any]]
        XCTAssertEqual(raw?.first?["name"] as? String, "todos")
        XCTAssertEqual(raw?.first?["text"] as? String, "TODO")
    }

    func testChangeIsAnnounced() {
        expectation(forNotification: .soquelSavedSearchesChanged, object: nil)
        SavedSearchStore.save(SavedSearch(name: "todos", query: sampleQuery()))
        waitForExpectations(timeout: 2)
    }
}
