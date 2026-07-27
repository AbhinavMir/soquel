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
