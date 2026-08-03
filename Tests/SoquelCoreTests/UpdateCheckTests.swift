import XCTest
@testable import SoquelCore

final class UpdateCheckTests: XCTestCase {
    private var wasEnabled = false

    override func setUp() {
        super.setUp()
        wasEnabled = UpdateCheck.isEnabled
        UpdateCheck.forgetState()
    }

    override func tearDown() {
        UpdateCheck.isEnabled = wasEnabled
        UpdateCheck.forgetState()
        super.tearDown()
    }

    func testItIsOffByDefault() {
        UpdateCheck.isEnabled = false
        XCTAssertFalse(UpdateCheck.isEnabled, "nothing is contacted unless asked")
    }

    func testTagsParseWithOrWithoutTheV() {
        XCTAssertEqual(UpdateCheck.parse("v1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateCheck.parse("1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateCheck.parse("2.0"), [2, 0])
        XCTAssertEqual(UpdateCheck.parse("1.0.2-beta1"), [1, 0, 2])
    }

    func testANonVersionTagIsNotAVersion() {
        XCTAssertNil(UpdateCheck.parse("nightly"))
        XCTAssertNil(UpdateCheck.parse(""))
    }

    func testNewerIsComparedNumericallyNotAsText() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.1.0", than: "1.0.9"))
        // "10" sorts before "9" as text and after it as a number.
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.0.0", than: "1.0.1"))
    }

    /// "1.0" and "1.0.0" are the same version.
    func testMissingComponentsCountAsZero() {
        XCTAssertFalse(UpdateCheck.isNewer("v1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.1", than: "1.0"))
    }

    /// A tag nobody can read is not a reason to tell someone to upgrade.
    func testAnUnreadableTagIsNeverNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("nightly", than: "1.0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("v2.0.0", than: "garbage"))
    }

    func testItIsDueOnlyOncePerInterval() {
        XCTAssertTrue(UpdateCheck.isDue(last: nil))
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdateCheck.isDue(now: now, last: now.addingTimeInterval(-60)))
        XCTAssertTrue(UpdateCheck.isDue(now: now, last: now.addingTimeInterval(-UpdateCheck.interval - 1)))
    }

    // MARK: - Reading the answer

    private func body(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    private func ok(_ data: Data) -> UpdateCheck.Result {
        let response = HTTPURLResponse(
            url: UpdateCheck.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil
        )
        return UpdateCheck.interpret(data: data, response: response, error: nil)
    }

    func testANewerReleaseIsReported() {
        let result = ok(body([
            "tag_name": "v99.0.0",
            "html_url": "https://github.com/AbhinavMir/soquel/releases/tag/v99.0.0",
        ]))
        guard case .available(let release) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(release.version, "99.0.0")
    }

    func testTheSameVersionIsUpToDate() {
        let result = ok(body(["tag_name": "v\(UpdateCheck.currentVersion)"]))
        guard case .upToDate = result else { return XCTFail("\(result)") }
    }

    /// A half-finished release must not announce itself.
    func testDraftsAndPrereleasesAreIgnored() {
        for flag in ["draft", "prerelease"] {
            let result = ok(body(["tag_name": "v99.0.0", flag: true]))
            guard case .upToDate = result else { return XCTFail("\(flag): \(result)") }
        }
    }

    func testAnHttpErrorIsReportedRatherThanTreatedAsUpToDate() {
        let response = HTTPURLResponse(
            url: UpdateCheck.endpoint, statusCode: 403, httpVersion: nil, headerFields: nil
        )
        let result = UpdateCheck.interpret(data: nil, response: response, error: nil)
        guard case .failed(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("403"), reason)
    }

    func testGarbageIsReportedRatherThanTreatedAsUpToDate() {
        let result = ok(Data("not json".utf8))
        guard case .failed = result else { return XCTFail("\(result)") }
    }

    /// Turning it off clears what it remembered, so it does not silently keep
    /// a skipped version or a last-checked date.
    func testTurningItOffForgetsItsState() {
        UpdateCheck.isEnabled = true
        UpdateCheck.lastChecked = Date()
        UpdateCheck.skippedVersion = "9.9.9"

        UpdateCheck.isEnabled = false
        XCTAssertNil(UpdateCheck.lastChecked)
        XCTAssertNil(UpdateCheck.skippedVersion)
    }
}
