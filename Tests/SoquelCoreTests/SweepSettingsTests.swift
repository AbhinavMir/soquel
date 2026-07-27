import XCTest
@testable import SoquelCore

/// Two ways the settings file could win an argument it had no business
/// winning: a change made while a write was in flight was left with no write
/// to carry it, and a write that failed was recorded as though it had landed.
/// Either one ends with the file being read back over what the user has just
/// set, and nothing said anywhere.
final class SweepSettingsTests: XCTestCase {
    private var url: URL!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sweep-settings-\(UUID().uuidString)/settings.json")
        store = SettingsStore(url: url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func json(_ dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
    }

    /// Runs the main queue, where the debounce lives, for long enough that a
    /// scheduled write and any write it arms in turn have both had their
    /// quarter second.
    private func settle(_ seconds: TimeInterval) {
        let settled = expectation(description: "writes settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 5)
    }

    /// Puts a plain file where the settings directory should be, so no write to
    /// `url` can land however it is attempted.
    private func blockTheDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
    }

    private func unblockTheDirectory() throws {
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private var wellPastTheSettlingWindow: Date {
        Date().addingTimeInterval(SettingsStore.settlingWindow + 1)
    }

    // MARK: - A set() that lands while a write is in flight

    /// The scheduled pass takes its snapshot, a set() lands, the pass finishes.
    /// That set() found a write already scheduled and so armed no timer of its
    /// own; if the pass then reports itself done, nothing is left to carry the
    /// value to the file and it is lost at quit.
    func testASetLandingAfterTheSnapshotIsStillWritten() {
        store.set("column", forKey: "viewMode")
        store.writeNow()                        // the pass, snapshotting "column"
        store.set("icon", forKey: "viewMode")   // lands after the snapshot
        XCTAssertTrue(store.hasUnwrittenChanges)

        store.finishScheduledWrite()            // the tail of the pass
        XCTAssertTrue(store.hasUnwrittenChanges, "the file has not got it yet")

        settle(0.8)
        XCTAssertFalse(store.hasUnwrittenChanges)
        XCTAssertEqual(store.string(forKey: "viewMode"), "icon")
        XCTAssertEqual(SettingsStore(url: url).string(forKey: "viewMode"), "icon",
                       "the value must not be left in memory only")
    }

    /// The other half of the same fault: with the value unwritten and nothing
    /// marked pending, the next watcher event past the settling window read the
    /// file and replaced every setting with what it said.
    func testTheFileCannotReplaceAValueThatIsStillUnwritten() throws {
        store.set("column", forKey: "viewMode")
        store.writeNow()
        store.set("icon", forKey: "viewMode")
        store.finishScheduledWrite()

        // Whatever the watcher reads next — a hand edit, or the older file
        // itself — memory holds a change the file has not got, so it must win.
        XCTAssertFalse(store.shouldAdopt(try json(["viewMode": "list"]), now: wellPastTheSettlingWindow),
                       "adopting the file here would undo the set() that raced the write")
        XCTAssertEqual(store.string(forKey: "viewMode"), "icon")
        settle(0.8)
    }

    /// The race as it actually happens: set() off the main thread, which the
    /// store supports, while the debounce runs on it.
    func testSetsFromAnotherThreadAllReachTheFile() {
        let done = expectation(description: "background sets finished")
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            for index in 0..<200 {
                store?.set("value-\(index)", forKey: "viewMode")
                Thread.sleep(forTimeInterval: 0.002)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        settle(0.8)

        XCTAssertFalse(store.hasUnwrittenChanges)
        XCTAssertEqual(store.string(forKey: "viewMode"), "value-199")
        XCTAssertEqual(SettingsStore(url: url).string(forKey: "viewMode"), "value-199")
    }

    // MARK: - A write that fails

    func testAFailedWriteIsNotRecordedAsDone() throws {
        try blockTheDirectory()
        store.set("column", forKey: "viewMode")
        settle(0.6)   // the scheduled write runs, and cannot land

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the write cannot have landed")
        XCTAssertTrue(store.hasUnwrittenChanges)
        XCTAssertFalse(store.shouldAdopt(try json(["viewMode": "icon"]), now: wellPastTheSettlingWindow),
                       "the file holds older values than memory does; it must not win")
        XCTAssertEqual(store.string(forKey: "viewMode"), "column")
    }

    /// The reported fault exactly: the bytes recorded as written were the ones
    /// the write was given rather than the ones the file received, so what the
    /// file really held looked like somebody else's edit and was adopted.
    func testAFailedWriteDoesNotCostTheChange() throws {
        store.set("column", forKey: "viewMode")
        settle(0.6)
        let onDisk = try Data(contentsOf: url)

        try blockTheDirectory()
        store.set("icon", forKey: "viewMode")
        settle(0.6)   // the scheduled write runs, and cannot land

        XCTAssertTrue(store.hasUnwrittenChanges)
        XCTAssertFalse(store.shouldAdopt(onDisk, now: wellPastTheSettlingWindow),
                       "those are the bytes we wrote, not an outside edit")
        XCTAssertEqual(store.string(forKey: "viewMode"), "icon",
                       "a write that failed must not revert what the user set")
    }

    /// The refusal is not permanent: once a write lands, a hand edit is read
    /// back as before.
    func testOutsideEditsAreBelievedAgainOnceAWriteLands() throws {
        try blockTheDirectory()
        store.set("column", forKey: "viewMode")
        settle(0.6)

        try unblockTheDirectory()
        store.writeNow()

        XCTAssertFalse(store.hasUnwrittenChanges)
        XCTAssertTrue(store.shouldAdopt(try json(["viewMode": "icon"]), now: wellPastTheSettlingWindow))
    }

    /// A write that cannot land must not become a write attempt every quarter
    /// second for the rest of the run. The next change is what retries it.
    func testAFailedWriteIsRetriedByTheNextChangeRatherThanOnALoop() throws {
        try blockTheDirectory()
        store.set("column", forKey: "viewMode")
        settle(0.6)

        try unblockTheDirectory()
        store.set("icon", forKey: "viewMode")
        settle(0.6)

        XCTAssertFalse(store.hasUnwrittenChanges)
        XCTAssertEqual(SettingsStore(url: url).string(forKey: "viewMode"), "icon")
    }
}
