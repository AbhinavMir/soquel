import XCTest
@testable import SoquelCore


/// Renumbering an already-numbered batch: the case a folder of records with a
/// hole in its sequence actually needs.
final class ResequenceTests: XCTestCase {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/soquel-resequence-test/\($0)") }
    }

    func testTheNumberChangesAndTheRestOfTheNameDoesNot() {
        let plan = BatchRename.plan(
            for: urls(["01_DAVIS_$22753.20_REC.pdf", "05_BENTEL_$20035.65_REC.pdf"]),
            rules: [.resequence(start: 1, padding: 0)]
        )
        XCTAssertEqual(plan[0].proposed, "01_DAVIS_$22753.20_REC.pdf")
        XCTAssertEqual(plan[1].proposed, "02_BENTEL_$20035.65_REC.pdf")
    }

    func testAGapIsClosed() {
        let plan = BatchRename.plan(
            for: urls(["01_a.txt", "02_b.txt", "04_c.txt", "05_d.txt"]),
            rules: [.resequence(start: 1, padding: 0)]
        )
        XCTAssertEqual(plan.map(\.proposed), ["01_a.txt", "02_b.txt", "03_c.txt", "04_d.txt"])
    }

    func testStartingSomewhereElseShiftsEverything() {
        let plan = BatchRename.plan(
            for: urls(["01_a.txt", "02_b.txt"]),
            rules: [.resequence(start: 7, padding: 0)]
        )
        XCTAssertEqual(plan.map(\.proposed), ["07_a.txt", "08_b.txt"])
    }

    func testTheWidthIsKeptUnlessOneIsAskedFor() {
        let kept = BatchRename.plan(for: urls(["001_a.txt"]), rules: [.resequence(start: 4, padding: 0)])
        XCTAssertEqual(kept[0].proposed, "004_a.txt")

        let widened = BatchRename.plan(for: urls(["1_a.txt"]), rules: [.resequence(start: 4, padding: 3)])
        XCTAssertEqual(widened[0].proposed, "004_a.txt")
    }

    /// A file with no number is not part of the sequence, and inventing one
    /// for it would renumber a set the user did not mean.
    func testAnUnnumberedFileIsLeftAlone() {
        let plan = BatchRename.plan(
            for: urls(["README.txt", "01_a.txt"]),
            rules: [.resequence(start: 1, padding: 0)]
        )
        XCTAssertEqual(plan[0].proposed, "README.txt")
        XCTAssertFalse(plan[0].changed)
        XCTAssertEqual(plan[1].proposed, "02_a.txt")
    }

    func testTheSeparatorIsWhateverItWas() {
        for name in ["01-a.txt", "01.a.txt", "01 a.txt", "01a.txt"] {
            let plan = BatchRename.plan(for: urls([name]), rules: [.resequence(start: 9, padding: 2)])
            XCTAssertEqual(plan[0].proposed, name.replacingOccurrences(of: "01", with: "09"))
        }
    }

    func testANumberedBatchIsRecognised() {
        XCTAssertTrue(BatchRename.isNumberedBatch(["01_a", "02_b", "README"]))
        XCTAssertFalse(BatchRename.isNumberedBatch(["alpha", "beta", "gamma"]))
    }
}
