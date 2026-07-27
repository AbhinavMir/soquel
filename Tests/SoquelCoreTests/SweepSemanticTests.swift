import XCTest
@testable import SoquelCore

/// The literal half of the ranking, which used to match substrings (#34).
///
/// `body.contains(term)` gave a query of "car" a full literal 1.0 against a
/// passage that only said "scar"; blended at a quarter of the score that is
/// enough to reorder the top of the list.
final class SweepSemanticTests: XCTestCase {
    private func score(_ query: String, _ passage: String, path: String = "/a/x.txt") -> Float {
        SemanticIndex.literalScore(terms: SemanticIndex.terms(of: query),
                                   passage: passage, path: path)
    }

    // MARK: - A word, not a run of letters

    func testATermInsideALongerWordDoesNotCount() {
        XCTAssertEqual(score("car", "the scar healed over"), 0, "\"scar\" counted as \"car\"")
        XCTAssertEqual(score("car", "carbon capture at the plant"), 0)
        XCTAssertEqual(score("car", "please discard the draft"), 0)
        XCTAssertEqual(score("art", "start the engine"), 0)
        XCTAssertEqual(score("art", "a single particle of dust"), 0)
    }

    func testATermInsideALongerWordOfTheFileNameDoesNotCount() {
        XCTAssertEqual(score("port", "figures attached", path: "/a/reports.txt"), 0,
                       "\"reports\" counted as \"port\"")
    }

    /// Only the words that are really there count, so a passage matching one of
    /// two terms scores a half rather than the whole.
    func testOnlyGenuineWordsCountTowardsTheFraction() {
        XCTAssertEqual(score("berlin revenue", "revenue from the scarborough office"), 0.5)
    }

    // MARK: - What must still match

    func testWholeWordsStillMatch() {
        XCTAssertEqual(score("berlin revenue", "revenue in berlin was up"), 1.0)
        XCTAssertEqual(score("Berlin", "BERLIN"), 1.0)
    }

    /// Punctuation is a boundary, not part of the word, so a term at the end of
    /// a sentence or inside brackets still counts.
    func testPunctuationDoesNotHideAWord() {
        XCTAssertEqual(score("berlin", "the office moved to berlin."), 1.0)
        XCTAssertEqual(score("berlin", "(berlin)"), 1.0)
        XCTAssertEqual(score("berlin", "munich, berlin, hamburg"), 1.0)
        XCTAssertEqual(score("art", "a state-of-the-art design"), 1.0,
                       "a hyphen separates words")
    }

    /// The file name is cut on the same boundaries, which is what lets a name
    /// stand in for contents that never say the words.
    func testTheFileNameStillCountsWordByWord() {
        XCTAssertEqual(score("berlin revenue", "figures attached", path: "/a/berlin-revenue.txt"), 1.0)
        XCTAssertEqual(score("berlin revenue", "figures attached", path: "/a/berlin_revenue.md"), 1.0)
        XCTAssertEqual(score("berlin revenue", "figures attached", path: "/a/revenue.berlin.txt"), 1.0)
        // Only the last component is the name; the folders above it are not.
        XCTAssertEqual(score("berlin", "figures attached", path: "/berlin/x.txt"), 0)
    }

    func testAnEmptyQueryStillScoresNothing() {
        XCTAssertEqual(SemanticIndex.literalScore(terms: [], passage: "berlin", path: "/a/x.txt"), 0)
    }

    // MARK: - What the blend does with it

    /// The spurious quarter is what made this worth fixing: a passage whose only
    /// claim on the query is a substring must not overtake a closer one.
    func testASubstringNoLongerOutranksACloserPassage() {
        let weight = SemanticIndex.literalWeight
        let semantic: Float = 1 - weight

        // Two entries, the second slightly closer by meaning.
        let substringOnly = 0.50 * semantic + score("car", "a scar and some carbon") * weight
        let closer = 0.55 * semantic + score("car", "nothing of the sort") * weight

        XCTAssertGreaterThan(closer, substringOnly,
                             "an invented literal match reordered the results")
    }

    // MARK: - The query itself

    /// The query and the text are now cut by the same tokeniser; splitting the
    /// query must not have changed.
    func testQueryTermsAreUnchanged() {
        XCTAssertEqual(SemanticIndex.terms(of: "the revenue for the Berlin office"),
                       ["revenue", "berlin", "office"])
        XCTAssertEqual(SemanticIndex.terms(of: "berlin-revenue.txt"), ["berlin", "revenue", "txt"])
    }
}
