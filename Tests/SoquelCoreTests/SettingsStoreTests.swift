import XCTest
@testable import SoquelCore

final class SettingsStoreTests: XCTestCase {
    private var url: URL!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-settings-\(UUID().uuidString)/settings.json")
        store = SettingsStore(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func testValuesSurviveAReload() {
        store.set(true, forKey: "showHiddenFiles")
        store.set(72.5, forKey: "iconSize")
        store.set(["a", "b"], forKey: "favouritePaths")
        store.writeNow()

        let reopened = SettingsStore(url: url)
        XCTAssertTrue(reopened.bool(forKey: "showHiddenFiles"))
        XCTAssertEqual(reopened.double(forKey: "iconSize"), 72.5)
        XCTAssertEqual(reopened.stringArray(forKey: "favouritePaths"), ["a", "b"])
    }

    /// The point of the file is that a person can read and edit it, so nothing
    /// may be stored as an opaque blob.
    func testCodableValuesAreWrittenAsReadableJSON() throws {
        store.encode(SoquelCore.SortOrder.default, forKey: "sortOrder")
        store.writeNow()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"sortOrder\""))
        XCTAssertTrue(text.contains("descriptors"))
        XCTAssertFalse(text.contains("base64"))

        let round = SettingsStore(url: url).decode(SoquelCore.SortOrder.self, forKey: "sortOrder")
        XCTAssertEqual(round?.descriptors, SoquelCore.SortOrder.default.descriptors)
    }

    func testHandEditedFileIsReadBack() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{ "iconSize": 128, "showGitStatus": false }"#.write(to: url, atomically: true, encoding: .utf8)

        let opened = SettingsStore(url: url)
        XCTAssertEqual(opened.double(forKey: "iconSize"), 128)
        XCTAssertEqual(opened.object(forKey: "showGitStatus") as? Bool, false)
    }

    func testMissingFileGivesAnEmptyStore() {
        XCTAssertNil(store.object(forKey: "anything"))
        XCTAssertFalse(store.bool(forKey: "showHiddenFiles"))
    }

    func testRemovingAKeyDropsItFromTheFile() throws {
        store.set("com.apple.Terminal", forKey: "terminalBundleID")
        store.removeObject(forKey: "terminalBundleID")
        store.writeNow()
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("terminalBundleID"))
    }

    /// A value the JSON encoder cannot represent must not be written, rather
    /// than corrupting the whole file.
    func testNonJSONValuesAreRejected() {
        store.set(Data([0x00, 0x01]), forKey: "bogus")
        XCTAssertNil(store.object(forKey: "bogus"))
        store.writeNow()
        XCTAssertNotNil(try? Data(contentsOf: url))
    }

    func testMigrationCopiesExistingDefaultsOnce() throws {
        let defaults = UserDefaults(suiteName: "soquel-migration-\(UUID().uuidString)")!
        defaults.set(true, forKey: "showHiddenFiles")
        defaults.set(96.0, forKey: "iconSize")

        store.migrateFromUserDefaults(defaults, keys: ["showHiddenFiles", "iconSize"])
        XCTAssertTrue(store.bool(forKey: "showHiddenFiles"))
        XCTAssertEqual(store.double(forKey: "iconSize"), 96)

        // A second run must not overwrite what the user has since edited.
        store.set(false, forKey: "showHiddenFiles")
        store.writeNow()
        store.migrateFromUserDefaults(defaults, keys: ["showHiddenFiles"])
        XCTAssertFalse(store.bool(forKey: "showHiddenFiles"))
    }

    func testEveryPrefsKeyIsDeclared() {
        // Prefs.keys drives migration; a property missing from it would lose
        // its value on upgrade.
        XCTAssertTrue(Prefs.keys.contains("showHiddenFiles"))
        XCTAssertTrue(Prefs.keys.contains("sortOrder"))
        XCTAssertTrue(Prefs.keys.contains("showInspector"))
        XCTAssertEqual(Set(Prefs.keys).count, Prefs.keys.count)
    }
}
