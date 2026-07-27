import XCTest
@testable import SoquelCore

final class TextExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ contents: String, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPlainTextIsRead() throws {
        let url = try write("the quarterly revenue report", "notes.txt")
        XCTAssertEqual(TextExtraction.text(of: url), "the quarterly revenue report")
    }

    func testSourceCodeCounts() throws {
        for name in ["a.swift", "b.py", "c.rs", "d.md", "e.json"] {
            XCTAssertTrue(TextExtraction.canRead(root.appendingPathComponent(name)), name)
        }
    }

    /// A format that would need a parser of its own is skipped, not half-read.
    func testBinaryFormatsAreSkipped() {
        for name in ["photo.jpg", "movie.mov", "archive.zip", "app.dmg", "sheet.xlsx"] {
            XCTAssertFalse(TextExtraction.canRead(root.appendingPathComponent(name)), name)
        }
    }

    /// Guessing an encoding produces mojibake, which embeds as nonsense.
    func testNonUTF8IsNotGuessedAt() throws {
        let url = root.appendingPathComponent("latin.txt")
        try Data([0xFF, 0xFE, 0x41, 0x00, 0x80, 0x81]).write(to: url)
        XCTAssertNil(TextExtraction.text(of: url))
    }

    func testHugeFilesAreSkipped() throws {
        let url = root.appendingPathComponent("huge.log")
        try Data(repeating: 0x41, count: TextExtraction.maximumBytes + 1024).write(to: url)
        XCTAssertNil(TextExtraction.text(of: url))
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(TextExtraction.clean("a  \t b\r\nc\n\n\n\nd"), "a b\nc\n\nd")
    }

    // MARK: - Passages

    func testShortTextIsOnePassage() {
        let passages = TextExtraction.passages("A short note about the Berlin office move.")
        XCTAssertEqual(passages.count, 1)
    }

    func testLongTextIsSplit() {
        let paragraph = String(repeating: "This sentence is here to take up room. ", count: 60)
        let passages = TextExtraction.passages(paragraph, target: 400)
        XCTAssertGreaterThan(passages.count, 3)
        for passage in passages {
            XCTAssertLessThan(passage.count, 700, "a passage ran well past the target")
        }
    }

    func testPassagesKeepParagraphsTogetherWhereTheyFit() {
        let text = "First paragraph, reasonably short.\n\nSecond paragraph, also short."
        XCTAssertEqual(TextExtraction.passages(text, target: 900).count, 1)
    }

    /// Fragments carry no meaning worth embedding.
    func testTinyFragmentsAreDropped() {
        XCTAssertTrue(TextExtraction.passages("ok\n\nyes\n\nno").isEmpty)
    }
}

final class SemanticIndexTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(SemanticIndex.isAvailable, "no sentence model on this machine")
    }

    // MARK: - The model

    func testVectorsAreUnitLength() throws {
        let v = try XCTUnwrap(SemanticIndex.vector(for: "the quarterly revenue report"))
        XCTAssertEqual(v.count, SemanticIndex.dimensions)
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.001)
    }

    /// The whole premise: two ways of saying the same thing land closer
    /// together than two unrelated things.
    func testRelatedTextScoresHigherThanUnrelated() throws {
        let a = try XCTUnwrap(SemanticIndex.vector(for: "the quarterly revenue report for the Berlin office"))
        let b = try XCTUnwrap(SemanticIndex.vector(for: "financial results from our German branch this quarter"))
        let c = try XCTUnwrap(SemanticIndex.vector(for: "how to bake sourdough bread at home"))

        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        let related = dot(a, b), unrelated = dot(a, c)
        XCTAssertGreaterThan(related, unrelated)
        XCTAssertGreaterThan(related - unrelated, 0.1, "the two are not separated by much")
    }

    func testEmptyTextHasNoVector() {
        XCTAssertNil(SemanticIndex.vector(for: ""))
    }

    // MARK: - Roots

    func testRootsAreRemembered() {
        Settings.removeObject(forKey: "semanticRoots")
        let folder = URL(fileURLWithPath: "/tmp/soquel-root-test")
        SemanticIndex.addRoot(folder)
        XCTAssertEqual(SemanticIndex.roots.map(\.path), [folder.path])

        // Adding twice must not list it twice.
        SemanticIndex.addRoot(folder)
        XCTAssertEqual(SemanticIndex.roots.count, 1)

        SemanticIndex.removeRoot(folder)
        XCTAssertTrue(SemanticIndex.roots.isEmpty)
        Settings.removeObject(forKey: "semanticRoots")
    }

    // MARK: - End to end

    func testIndexesAFolderAndFindsByMeaning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-semantic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        The Berlin office reported strong quarterly revenue this year. Sales grew across \
        every product line and the regional team exceeded its target for the third quarter \
        running. Costs were held flat against the previous period.
        """.write(to: root.appendingPathComponent("finance.txt"), atomically: true, encoding: .utf8)

        try """
        To make a sourdough loaf, feed the starter twelve hours before mixing. Combine flour \
        and water and rest the dough, then fold it every half hour for two hours before \
        shaping it and proving overnight in the fridge.
        """.write(to: root.appendingPathComponent("bread.txt"), atomically: true, encoding: .utf8)

        let index = SemanticIndex.shared
        index.clear()
        let built = expectation(description: "indexed")
        index.rebuild(roots: [root], progress: { _ in }, finished: { _ in built.fulfill() })
        wait(for: [built], timeout: 90)

        XCTAssertEqual(index.fileCount, 2)
        XCTAssertGreaterThan(index.entryCount, 0)

        // The words "financial results" and "German branch" appear in neither
        // file; a literal search would find nothing.
        let hits = index.search("financial results from the German branch", minimumScore: 0.1)
        XCTAssertEqual(hits.first?.url.lastPathComponent, "finance.txt",
                       "meaning search picked the wrong document")
        XCTAssertFalse(hits.first?.passage.isEmpty ?? true, "a hit should carry the passage")

        let baking = index.search("recipe for bread dough", minimumScore: 0.1)
        XCTAssertEqual(baking.first?.url.lastPathComponent, "bread.txt")

        index.clear()
    }

    func testSearchingAnEmptyIndexFindsNothing() {
        SemanticIndex.shared.clear()
        XCTAssertTrue(SemanticIndex.shared.search("anything at all").isEmpty)
    }

    /// One result per file, so five passages from one document cannot fill the
    /// list and push everything else off it.
    func testOneResultPerFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repeated = (0..<8).map { index in
            "Passage number \(index) about quarterly revenue in the Berlin office and its sales figures."
        }.joined(separator: "\n\n")
        try repeated.write(to: root.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)

        let index = SemanticIndex.shared
        index.clear()
        let built = expectation(description: "indexed")
        index.rebuild(roots: [root], progress: { _ in }, finished: { _ in built.fulfill() })
        wait(for: [built], timeout: 90)

        let hits = index.search("revenue in Berlin", minimumScore: 0.05)
        XCTAssertEqual(Set(hits.map(\.url.path)).count, hits.count, "a file appeared twice")
        index.clear()
    }
}
