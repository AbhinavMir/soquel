import XCTest
@testable import SoquelCore

final class LogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Log.clearBuffer()
    }

    override func tearDown() {
        Log.clearBuffer()
        try? FileManager.default.removeItem(at: Log.directory)
        super.tearDown()
    }

    func testTestsDoNotWriteToTheUsersLogFolder() {
        XCTAssertFalse(Log.directory.path.hasSuffix("Library/Logs/Soquel"))
    }

    func testAnEntryCarriesLevelCategoryAndMessage() {
        Log.info(.ui, "the pill was rebuilt")
        let entry = Log.everything.last ?? ""
        XCTAssertTrue(entry.contains("INFO"))
        XCTAssertTrue(entry.contains("[ui]"))
        XCTAssertTrue(entry.contains("the pill was rebuilt"))
    }

    /// The origin is what turns "something failed" into a place to look.
    func testAnEntryNamesWhereItCameFrom() {
        Log.error(.files, "could not copy")
        XCTAssertTrue(Log.everything.last?.contains("LogTests.swift") ?? false)
    }

    func testEveryLevelIsRecorded() {
        Log.debug(.app, "d")
        Log.info(.app, "i")
        Log.warn(.app, "w")
        Log.error(.app, "e")
        let text = Log.everything.joined(separator: "\n")
        for level in ["DEBUG", "INFO", "WARN", "ERROR"] {
            XCTAssertTrue(text.contains(level), "\(level) missing")
        }
    }

    func testTheBufferIsBounded() {
        for index in 0..<(Log.bufferLimit + 500) { Log.debug(.app, "entry \(index)") }
        XCTAssertEqual(Log.everything.count, Log.bufferLimit)
        // The newest are the ones kept.
        XCTAssertTrue(Log.everything.last?.contains("entry \(Log.bufferLimit + 499)") ?? false)
    }

    func testRecentCarriesAHeaderNamingTheBuild() {
        Log.info(.app, "hello")
        let report = Log.recent(minutes: 3)
        XCTAssertTrue(report.contains("Soquel"))
        XCTAssertTrue(report.contains("Last 3 minutes"))
        XCTAssertTrue(report.contains(Log.directory.path))
        XCTAssertTrue(report.contains("hello"))
    }

    /// An empty window says so rather than handing over a bare header that
    /// looks like the logging is broken.
    func testAnEmptyWindowSaysSo() {
        XCTAssertTrue(Log.recent(minutes: 3).contains("nothing logged"))
    }

    func testEntriesAreWrittenToTodaysFile() throws {
        Log.info(.app, "written to disk")
        // The write is queued; give it a turn.
        let written = expectation(description: "file written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 5)

        let text = try String(contentsOf: Log.fileURL(for: Date()), encoding: .utf8)
        XCTAssertTrue(text.contains("written to disk"))
    }

    // MARK: - Housekeeping

    private func makeLogFile(daysOld: Double) throws -> URL {
        try FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        let url = Log.directory.appendingPathComponent("soquel-old-\(UUID().uuidString).log")
        try Data("stale".utf8).write(to: url)
        let stamp = Date().addingTimeInterval(-daysOld * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        return url
    }

    func testFilesOlderThanADayAreRemoved() throws {
        let old = try makeLogFile(daysOld: 2)
        XCTAssertEqual(Log.removeOldFiles(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testRecentFilesAreKept() throws {
        let fresh = try makeLogFile(daysOld: 0.25)
        XCTAssertEqual(Log.removeOldFiles(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Deleting the file currently being appended to would lose this session.
    func testTodaysFileIsNeverRemoved() throws {
        try FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        let today = Log.fileURL(for: Date())
        try Data("current".utf8).write(to: today)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-5 * 24 * 60 * 60)],
            ofItemAtPath: today.path
        )
        Log.removeOldFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
    }

    func testNonLogFilesAreLeftAlone() throws {
        try FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        let other = Log.directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: other.path
        )
        Log.removeOldFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testHousekeepingOnAMissingFolderIsHarmless() {
        try? FileManager.default.removeItem(at: Log.directory)
        XCTAssertEqual(Log.removeOldFiles(), 0)
    }
}
