import XCTest
@testable import SoquelCore

/// The version scheme, and which releases each channel is offered.
final class UpdateChannelTests: XCTestCase {

    func testReadsTheThreeNumbers() {
        XCTAssertEqual(Version("1.2.3"), Version(1, 2, 3))
        XCTAssertEqual(Version("v1.2.3"), Version(1, 2, 3))
        XCTAssertEqual(Version("1.2"), Version(1, 2, 0))
        XCTAssertEqual(Version("2"), Version(2, 0, 0))
        XCTAssertEqual(Version("1.2.3-beta1"), Version(1, 2, 3))
        XCTAssertNil(Version("nightly"))
        XCTAssertNil(Version(""))
        XCTAssertNil(Version("1.2.3.4"))
    }

    /// The oldest bug in version handling: "1.10.0" sorts before "1.9.0" as
    /// text and after it as numbers.
    func testTenIsNewerThanNine() {
        XCTAssertTrue(Version(1, 10, 0) > Version(1, 9, 0))
        XCTAssertTrue(Version(2, 0, 0) > Version(1, 99, 99))
        XCTAssertTrue(Version(1, 2, 1) > Version(1, 2, 0))
    }

    /// The middle number is a sequential release; the last one is a nightly.
    func testWhichNumberMeansWhat() {
        XCTAssertFalse(Version(1, 2, 0).isNightly)
        XCTAssertFalse(Version(2, 0, 0).isNightly)
        XCTAssertTrue(Version(1, 2, 1).isNightly)

        XCTAssertTrue(Version(1, 2, 0).suits(.stable))
        XCTAssertFalse(Version(1, 2, 1).suits(.stable), "a nightly must not reach stable")
        XCTAssertTrue(Version(1, 2, 1).suits(.nightly))
        XCTAssertTrue(Version(1, 2, 0).suits(.nightly), "nightly gets sequential releases too")
    }

    private func releases(_ tags: [String], prerelease: Bool = false) -> [AutoUpdate.Release] {
        tags.compactMap { tag in
            Version(tag).map {
                AutoUpdate.Release(version: $0,
                                   page: URL(string: "https://example.invalid")!,
                                   notes: nil, isPrerelease: prerelease)
            }
        }
    }

    func testStableSkipsNightliesAndTakesTheNewestRelease() {
        let list = releases(["1.3.0", "1.2.4", "1.2.3", "1.2.0"])
        let best = AutoUpdate.best(from: list, channel: .stable, current: Version(1, 2, 0))
        XCTAssertEqual(best?.version, Version(1, 3, 0))
    }

    func testNightlyTakesTheNewestOfEverything() {
        let list = releases(["1.3.0", "1.3.2", "1.2.4"])
        let best = AutoUpdate.best(from: list, channel: .nightly, current: Version(1, 2, 0))
        XCTAssertEqual(best?.version, Version(1, 3, 2))
    }

    /// Nothing older than what is running, on either channel.
    func testAnOlderReleaseIsNeverOffered() {
        let list = releases(["1.1.0", "1.0.11"])
        XCTAssertNil(AutoUpdate.best(from: list, channel: .stable, current: Version(1, 2, 0)))
        XCTAssertNil(AutoUpdate.best(from: list, channel: .nightly, current: Version(1, 2, 0)))
        XCTAssertNil(AutoUpdate.best(from: releases(["1.2.0"]), channel: .stable,
                                     current: Version(1, 2, 0)), "the same version is not an update")
    }

    /// A sequential release marked prerelease while it is being tried out is
    /// still sequential, and stable should be offered it. The channel decides
    /// by the number, not by GitHub's flag.
    func testABetaSequentialReleaseStillReachesStable() {
        let list = releases(["1.2.0"], prerelease: true)
        let best = AutoUpdate.best(from: list, channel: .stable, current: Version(1, 1, 1))
        XCTAssertEqual(best?.version, Version(1, 2, 0))
    }

    func testDraftsAreSkippedAndPrereleasesAreKept() {
        let json = """
        [{"tag_name":"v1.3.0","draft":true,"prerelease":false,"html_url":"https://x.invalid"},
         {"tag_name":"v1.2.1","draft":false,"prerelease":true,"html_url":"https://x.invalid"},
         {"tag_name":"not-a-version","draft":false,"prerelease":false,"html_url":"https://x.invalid"},
         {"tag_name":"v1.2.0","draft":false,"prerelease":false,"html_url":"https://x.invalid"}]
        """
        let parsed = AutoUpdate.parse(Data(json.utf8))
        XCTAssertEqual(parsed.map(\.version), [Version(1, 2, 1), Version(1, 2, 0)])
        XCTAssertTrue(parsed[0].isPrerelease)
    }

    func testRubbishIsNotAReleaseList() {
        XCTAssertTrue(AutoUpdate.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(AutoUpdate.parse(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(AutoUpdate.parse(Data()).isEmpty)
    }

    /// Nightlies land more often, so they are asked about more often.
    func testNightlyChecksMoreOften() {
        let was = UpdateChannel.current
        defer { UpdateChannel.current = was }
        UpdateChannel.current = .nightly
        let nightly = AutoUpdate.interval
        UpdateChannel.current = .stable
        XCTAssertLessThan(nightly, AutoUpdate.interval)
    }
}
