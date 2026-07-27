import XCTest
@testable import SoquelCore

/// The settings watcher must never overwrite a newer in-memory value with an
/// older one from disk. It did: every view-mode change was reverted a quarter
/// of a second later by the app's own write being read back mid-save.
final class SettingsWatcherTests: XCTestCase {
    private var url: URL!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-watch-\(UUID().uuidString)/settings.json")
        store = SettingsStore(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func json(_ dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
    }

    func testOurOwnBytesAreNotAnOutsideChange() throws {
        store.set("column", forKey: "viewMode")
        store.writeNow()
        let ours = try Data(contentsOf: url)
        XCTAssertFalse(store.shouldAdopt(ours))
    }

    /// The case that actually bit: an atomic save is a create then a rename,
    /// so the watcher can read the file while it still holds the old contents.
    func testAStaleReadDuringOurOwnWriteIsIgnored() throws {
        store.set("column", forKey: "viewMode")
        store.writeNow()
        let stale = try json(["viewMode": "icon"])
        XCTAssertFalse(store.shouldAdopt(stale), "a stale read just after our write must not win")
    }

    func testAnOutsideChangeIsTakenOnceTheWriteHasSettled() throws {
        store.set("column", forKey: "viewMode")
        // Let the debounced write actually run, so nothing is pending.
        let settled = expectation(description: "write settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        let theirs = try json(["viewMode": "icon"])
        let later = Date().addingTimeInterval(SettingsStore.settlingWindow + 1)
        XCTAssertTrue(store.shouldAdopt(theirs, now: later))
    }

    /// With a write still queued, memory is ahead of the file by design and the
    /// file must not win.
    func testAPendingWriteBeatsTheFile() throws {
        store.set("column", forKey: "viewMode")   // schedules a debounced write
        let stale = try json(["viewMode": "list"])
        XCTAssertFalse(store.shouldAdopt(stale))
    }

    func testAnUntouchedStoreTakesWhateverIsOnDisk() throws {
        let fresh = SettingsStore(url: url)
        XCTAssertTrue(fresh.shouldAdopt(try json(["viewMode": "icon"])))
    }

    /// End to end: set a value, let the debounce and the settling window pass,
    /// and it must still be the value that was set.
    func testAValueSurvivesItsOwnWrite() {
        store.set("column", forKey: "viewMode")
        let settled = expectation(description: "write settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.string(forKey: "viewMode"), "column")
    }

    func testRapidChangesKeepTheLastOne() {
        for mode in ["list", "icon", "column", "list", "icon"] {
            store.set(mode, forKey: "viewMode")
        }
        let settled = expectation(description: "writes settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.string(forKey: "viewMode"), "icon")
        XCTAssertEqual(SettingsStore(url: url).string(forKey: "viewMode"), "icon")
    }
}
