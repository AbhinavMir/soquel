import XCTest
@testable import SoquelCore

final class ArchiverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func write(_ path: String, _ body: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(body.utf8).write(to: url)
        return url
    }

    /// Lists what actually ended up in the archive.
    private func entries(of archive: URL) throws -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-Z1", archive.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    private func compress(_ urls: [URL]) throws -> Archiver.Outcome {
        var result: Archiver.Outcome?
        let done = expectation(description: "compressed")
        Archiver.compress(urls) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result)
    }

    /// The whole point: none of the macOS bookkeeping goes in.
    func testTheArchiveHasNoMacOSLitter() throws {
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try write("Project/notes.txt", "hello")
        try write("Project/deep/more.txt", "world")
        try write("Project/.DS_Store", "junk")
        try write("Project/deep/.DS_Store", "junk")
        try write("Project/._notes.txt", "resource fork")

        let outcome = try compress([folder])
        let archive = try XCTUnwrap(outcome.archive, outcome.message)
        let names = try entries(of: archive)

        XCTAssertTrue(names.contains { $0.hasSuffix("notes.txt") && !$0.contains("._") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("more.txt") }, "\(names)")

        for name in names {
            XCTAssertFalse(name.contains(".DS_Store"), name)
            XCTAssertFalse(name.contains("__MACOSX"), name)
            XCTAssertFalse((name as NSString).lastPathComponent.hasPrefix("._"), name)
        }
    }

    /// Paths are relative, or the archive carries /Users/you inside it.
    func testTheArchiveDoesNotCarryTheWholePath() throws {
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try write("Project/notes.txt")

        let archive = try XCTUnwrap(try compress([folder]).archive)
        for name in try entries(of: archive) {
            XCTAssertFalse(name.hasPrefix("/"), name)
            XCTAssertFalse(name.contains("soquel-zip-"), name)
        }
    }

    /// One item takes its own name; several take the folder's, not "Archive".
    func testTheNameSaysWhatIsInIt() {
        let folder = URL(fileURLWithPath: "/tmp/Work", isDirectory: true)
        let one = folder.appendingPathComponent("notes.txt")
        let two = folder.appendingPathComponent("budget.csv")

        XCTAssertEqual(Archiver.archiveName(for: [one], in: folder), "notes.zip")
        XCTAssertEqual(Archiver.archiveName(for: [one, two], in: folder), "Work.zip")
    }

    /// Compressing twice does not overwrite the first archive.
    func testASecondArchiveGetsItsOwnName() throws {
        try write("notes.txt")
        let first = try XCTUnwrap(try compress([root.appendingPathComponent("notes.txt")]).archive)
        let second = try XCTUnwrap(try compress([root.appendingPathComponent("notes.txt")]).archive)

        XCTAssertEqual(first.lastPathComponent, "notes.zip")
        XCTAssertEqual(second.lastPathComponent, "notes 2.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    /// Every exclusion is matched at the top level and at any depth.
    func testExclusionsCoverNestedPaths() {
        let args = Archiver.arguments(archive: URL(fileURLWithPath: "/tmp/a.zip"), items: ["x"])
        XCTAssertTrue(args.contains("-X"), "no AppleDouble attributes")
        for pattern in Archiver.excluded {
            XCTAssertTrue(args.contains(pattern), pattern)
            XCTAssertTrue(args.contains("*/\(pattern)"), "nested \(pattern)")
        }
    }

    func testTheMenuTitleNamesWhatHappens() {
        let one = URL(fileURLWithPath: "/tmp/notes.txt")
        XCTAssertEqual(Archiver.menuTitle(for: [one]), "Compress “notes.txt”")
        XCTAssertEqual(Archiver.menuTitle(for: [one, one]), "Compress 2 Items")
    }

    func testCompressingNothingSaysSo() throws {
        XCTAssertNil(try compress([]).archive)
    }
}
