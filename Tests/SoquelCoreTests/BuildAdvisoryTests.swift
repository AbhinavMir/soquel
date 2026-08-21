import XCTest
@testable import SoquelCore

/// The recall check: reading the published list, and deciding whether the
/// build in hand is on it.
final class BuildAdvisoryTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testReadsAPublishedAdvisory() {
        let list = BuildAdvisory.parse(data("""
        {"advisories":[{"affects":["1.1.0"],"severity":"critical",
          "summary":"Diff with Current can empty a file.",
          "detail":"A branch name was read as an option.",
          "fixedIn":"1.1.1","rollBackTo":"1.0.11"}]}
        """))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].severity, .critical)
        XCTAssertEqual(list[0].fixedIn, "1.1.1")
        XCTAssertEqual(list[0].rollBackTo, "1.0.11")
        XCTAssertTrue(list[0].applies(to: "1.1.0"))
        XCTAssertFalse(list[0].applies(to: "1.1.1"), "the fix must not warn about itself")
        XCTAssertFalse(list[0].applies(to: "1.0.11"))
    }

    /// The file that is actually published has to be readable by the code
    /// that reads it, which a hand-written JSON file does not guarantee.
    func testTheShippedAdvisoryFileParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("site/advisories.json")
        let list = BuildAdvisory.parse(try Data(contentsOf: url))
        XCTAssertFalse(list.isEmpty, "site/advisories.json parses to nothing")
        let recalled = BuildAdvisory.advisory(for: "1.1.0", in: list)
        XCTAssertNotNil(recalled, "1.1.0 was withdrawn and must be on the list")
        XCTAssertEqual(recalled?.fixedIn, "1.1.1")
    }

    /// One malformed record must not hide a real recall sitting beside it.
    func testABrokenEntryDoesNotHideTheOthers() {
        let list = BuildAdvisory.parse(data("""
        {"advisories":[
          {"affects":[],"severity":"critical","summary":"no versions"},
          {"severity":"critical","summary":"no affects key"},
          {"affects":["1.1.0"],"severity":"nonsense","summary":"bad severity"},
          {"affects":["1.1.0"],"severity":"serious","summary":"a real one"}]}
        """))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].summary, "a real one")
    }

    func testRubbishIsNotAnAdvisory() {
        XCTAssertTrue(BuildAdvisory.parse(data("not json at all")).isEmpty)
        XCTAssertTrue(BuildAdvisory.parse(data("{}")).isEmpty)
        XCTAssertTrue(BuildAdvisory.parse(data("[]")).isEmpty)
        XCTAssertTrue(BuildAdvisory.parse(Data()).isEmpty)
    }

    /// Where two apply, the one that loses data is the one shown.
    func testTheWorstAdvisoryWins() {
        let list = BuildAdvisory.parse(data("""
        {"advisories":[
          {"affects":["1.1.0"],"severity":"serious","summary":"wrong line numbers"},
          {"affects":["1.1.0"],"severity":"critical","summary":"loses a file"}]}
        """))
        XCTAssertEqual(BuildAdvisory.advisory(for: "1.1.0", in: list)?.summary, "loses a file")
        XCTAssertNil(BuildAdvisory.advisory(for: "1.0.9", in: list))
    }

    /// A critical notice interrupts; a serious one does not.
    func testOnlyACriticalNoticeInterrupts() {
        XCTAssertTrue(BuildAdvisory.Severity.critical.isInterrupting)
        XCTAssertFalse(BuildAdvisory.Severity.serious.isInterrupting)
    }

    /// The download must come from the release page for that exact version.
    func testDownloadURLMatchesHowReleasesAreNamed() {
        XCTAssertEqual(
            Installer.downloadURL(for: "1.1.1")?.absoluteString,
            "https://github.com/AbhinavMir/soquel/releases/download/v1.1.1/Soquel-1.1.1.dmg")
        XCTAssertEqual(
            Installer.downloadURL(for: "1.0.11")?.absoluteString,
            "https://github.com/AbhinavMir/soquel/releases/download/v1.0.11/Soquel-1.0.11.dmg")
    }

    /// The signature gate names this developer and this application. If either
    /// half is dropped the installer will accept somebody else's build.
    func testTheSignatureRequirementIsSpecific() {
        XCTAssertTrue(Installer.requirement.contains("app.soquel.Soquel"))
        XCTAssertTrue(Installer.requirement.contains("P4ANTPX4G4"))
        XCTAssertTrue(Installer.requirement.contains("anchor apple generic"))
    }
}
