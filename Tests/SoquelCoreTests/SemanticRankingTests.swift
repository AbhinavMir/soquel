import XCTest
@testable import SoquelCore

/// The parts of ranking that do not need the model.
final class SemanticRankingTests: XCTestCase {
    func testCommonWordsAreDroppedFromAQuery() {
        XCTAssertEqual(SemanticIndex.terms(of: "the revenue for the Berlin office"),
                       ["revenue", "berlin", "office"])
    }

    func testShortWordsAreDropped() {
        XCTAssertEqual(SemanticIndex.terms(of: "a b cd tax"), ["tax"])
    }

    func testAnEmptyQueryHasNoTerms() {
        XCTAssertTrue(SemanticIndex.terms(of: "   ").isEmpty)
    }

    func testLiteralScoreCountsMatchingWords() {
        let terms = SemanticIndex.terms(of: "berlin revenue")
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: terms, passage: "revenue in berlin was up", path: "/a/x.txt"),
            1.0)
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: terms, passage: "revenue was up", path: "/a/x.txt"),
            0.5)
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: terms, passage: "nothing relevant", path: "/a/x.txt"),
            0)
    }

    /// A file called berlin-revenue.txt is about Berlin revenue whatever its
    /// contents happen to say.
    func testTheFileNameCounts() {
        let terms = SemanticIndex.terms(of: "berlin revenue")
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: terms, passage: "figures attached",
                                       path: "/a/berlin-revenue.txt"),
            1.0)
    }

    func testMatchingIsCaseInsensitive() {
        let terms = SemanticIndex.terms(of: "Berlin")
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: terms, passage: "BERLIN", path: "/a/x.txt"), 1.0)
    }

    func testAQueryOfOnlyStopWordsScoresNothing() {
        XCTAssertEqual(
            SemanticIndex.literalScore(terms: SemanticIndex.terms(of: "the and of"),
                                       passage: "anything", path: "/a/x.txt"),
            0)
    }

    /// Meaning still carries most of the weight; the literal part only breaks
    /// ties in favour of a document that says the words.
    func testMeaningStillDominates() {
        XCTAssertLessThan(SemanticIndex.literalWeight, 0.5)
        XCTAssertGreaterThan(SemanticIndex.literalWeight, 0)
    }

    func testThereIsAlwaysAtLeastOneWorker() {
        XCTAssertGreaterThanOrEqual(SemanticIndex.workerCount, 1)
    }
}

/// Bugs found by the sweep, each one a wrong search result.
final class SemanticSweepTests: XCTestCase {
    // MARK: - Scoping (#18)

    func testAFolderIsNotInsideItsSimilarlyNamedSibling() {
        XCTAssertTrue(SemanticIndex.path("/Users/x/Notes/a.md", isWithin: "/Users/x/Notes"))
        XCTAssertTrue(SemanticIndex.path("/Users/x/Notes", isWithin: "/Users/x/Notes"))
        XCTAssertFalse(SemanticIndex.path("/Users/x/Notes-archive/a.md", isWithin: "/Users/x/Notes"),
                       "a sibling folder was treated as being inside")
        XCTAssertFalse(SemanticIndex.path("/Users/x/Documents-old", isWithin: "/Users/x/Documents"))
        // A trailing separator on the folder must not change the answer.
        XCTAssertTrue(SemanticIndex.path("/Users/x/Notes/a.md", isWithin: "/Users/x/Notes/"))
    }

    // MARK: - Roots (#13)

    func testAddingAFolderAlreadyCoveredByARootDoesNothing() {
        Settings.removeObject(forKey: "semanticRoots")
        defer { Settings.removeObject(forKey: "semanticRoots") }

        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Documents"))
        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Documents/Work"))
        XCTAssertEqual(SemanticIndex.roots.map(\.path), ["/tmp/soq/Documents"],
                       "a nested root would walk the shared files twice")
    }

    func testAddingAFolderThatContainsExistingRootsReplacesThem() {
        Settings.removeObject(forKey: "semanticRoots")
        defer { Settings.removeObject(forKey: "semanticRoots") }

        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Documents/Work"))
        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Documents/Home"))
        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Documents"))
        XCTAssertEqual(SemanticIndex.roots.map(\.path), ["/tmp/soq/Documents"])
    }

    /// A sibling whose name merely starts the same is a separate root.
    func testASimilarlyNamedSiblingIsStillItsOwnRoot() {
        Settings.removeObject(forKey: "semanticRoots")
        defer { Settings.removeObject(forKey: "semanticRoots") }

        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Notes"))
        SemanticIndex.addRoot(URL(fileURLWithPath: "/tmp/soq/Notes-archive"))
        XCTAssertEqual(SemanticIndex.roots.count, 2)
    }
}

/// Passage splitting (#14, #35).
final class PassageSplittingTests: XCTestCase {
    /// Minified JS, a one-line CSV, an SVG: no blank line and no ". ", so every
    /// splitting rule passed the file through whole.
    func testTextWithNothingToBreakOnIsStillCutUp() {
        let minified = String(repeating: "a=1;b=2;c=3;", count: 4000)   // ~48k, no "\n\n", no ". "
        let passages = TextExtraction.passages(minified, target: 900)

        XCTAssertGreaterThan(passages.count, 10, "the whole file came back as one passage")
        for passage in passages {
            XCTAssertLessThanOrEqual(passage.count, 900,
                                     "a passage ran past the target with nothing to break on")
        }
    }

    func testTheWholeOfSuchTextIsStillCovered() {
        let text = String(repeating: "xy", count: 3000)
        let passages = TextExtraction.passages(text, target: 400, overlap: 50)
        XCTAssertTrue(passages.contains { $0.hasPrefix("xyxy") })
        XCTAssertTrue(passages.contains { $0.hasSuffix("xyxy") }, "the tail was dropped")
    }

    /// A first paragraph just under the target made `current` empty at the
    /// mid-loop append, which emitted "" as a passage.
    func testNoEmptyOrTinyPassageIsEmitted() {
        let first = String(repeating: "w", count: 899)
        let second = String(repeating: "z", count: 400)
        for passage in TextExtraction.passages(first + "\n\n" + second, target: 900) {
            XCTAssertFalse(passage.isEmpty, "an empty passage was emitted")
            XCTAssertGreaterThan(passage.count, 24)
        }
    }
}
