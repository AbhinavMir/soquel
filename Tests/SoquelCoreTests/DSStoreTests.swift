import XCTest
@testable import SoquelCore

final class DSStoreTests: XCTestCase {
    /// Every real .DS_Store on this machine parses without crashing, and the
    /// ones that carry a view style give a view this application has.
    func testRealFilesParse() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Downloads", "Desktop", "Documents"].map {
            home.appendingPathComponent($0).appendingPathComponent(".DS_Store")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }

        try XCTSkipIf(candidates.isEmpty, "no .DS_Store on this machine")

        var parsed = 0
        for file in candidates {
            guard let records = DSStore.records(in: file) else { continue }
            parsed += 1
            XCTAssertFalse(records.isEmpty, file.path)
            for record in records {
                XCTAssertEqual(record.key.count, 4, "\(record.filename) → \(record.key)")
            }
        }
        XCTAssertGreaterThan(parsed, 0, "none of \(candidates.count) files parsed")
    }

    /// Garbage in gives nil out rather than a trap: the lengths in this format
    /// come from a file the application did not write.
    func testMalformedInputIsRefused() {
        XCTAssertNil(DSStore.records(in: Data()))
        XCTAssertNil(DSStore.records(in: Data(repeating: 0, count: 64)))
        XCTAssertNil(DSStore.records(in: Data("not a ds_store at all".utf8)))

        // Right magic, nonsense after it.
        var header = Data([0, 0, 0, 1])
        header.append(contentsOf: Array("Bud1".utf8))
        header.append(Data(repeating: 0xFF, count: 60))
        XCTAssertNil(DSStore.records(in: header))
    }

    func testFinderViewStylesMap() {
        XCTAssertEqual(DSStore.viewMode(for: "icnv"), .icon)
        XCTAssertEqual(DSStore.viewMode(for: "clmv"), .column)
        XCTAssertEqual(DSStore.viewMode(for: "Nlsv"), .list)
        // Cover Flow has no equivalent, and guessing would put someone in a
        // view they never chose.
        XCTAssertNil(DSStore.viewMode(for: "Flwv"))
        XCTAssertNil(DSStore.viewMode(for: "junk"))
    }

    func testListViewPlistIsRead() {
        var settings = DSStore.Settings()
        DSStore.apply(listViewPlist: [
            "sortColumn": "dateModified",
            "ascending": false,
            "columns": [
                ["identifier": "name", "width": 300.0],
                ["identifier": "size", "width": 97.0],
            ],
        ], to: &settings)

        XCTAssertEqual(settings.sortColumn, "dateModified")
        XCTAssertEqual(settings.sortAscending, false)
        XCTAssertEqual(settings.columnWidths["name"], 300)
        XCTAssertEqual(settings.columnWidths["size"], 97)
    }

    /// Older files key the columns by identifier instead of listing them.
    func testTheOlderColumnShapeIsAlsoRead() {
        var settings = DSStore.Settings()
        DSStore.apply(listViewPlist: [
            "columns": ["name": ["width": 250.0], "kind": ["width": 110.0]],
        ], to: &settings)
        XCTAssertEqual(settings.columnWidths["name"], 250)
        XCTAssertEqual(settings.columnWidths["kind"], 110)
    }

    func testFinderColumnNamesTranslate() {
        XCTAssertEqual(DSStore.columnIdentifier(forFinder: "dateModified"), "modified")
        XCTAssertEqual(DSStore.columnIdentifier(forFinder: "ubsz"), "size")
        XCTAssertNil(DSStore.columnIdentifier(forFinder: "label"))
    }

    func testEmptySettingsAreReportedEmpty() {
        XCTAssertTrue(DSStore.Settings().isEmpty)
        var one = DSStore.Settings()
        one.viewMode = .icon
        XCTAssertFalse(one.isEmpty)
    }
}
