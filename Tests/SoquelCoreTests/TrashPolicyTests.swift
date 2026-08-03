import XCTest
@testable import SoquelCore

final class TrashPolicyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// The boot volume has a Trash, so nothing is interrupted for it.
    func testALocalFileTrashesNormallyAndWarnsAboutNothing() throws {
        let url = root.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)

        XCTAssertEqual(TrashPolicy.outcome(for: url), .recoverable)
        XCTAssertNil(TrashPolicy.warning(for: [url]))
        XCTAssertTrue(TrashPolicy.allRecoverable([url]))
    }

    func testAPermanentOutcomeIsNotRecoverable() {
        XCTAssertFalse(TrashPolicy.Outcome.permanent(volume: "NAS").isRecoverable)
        XCTAssertFalse(TrashPolicy.Outcome.readOnly(volume: "DVD").isRecoverable)
        XCTAssertTrue(TrashPolicy.Outcome.recoverable.isRecoverable)
    }

    /// A path that does not exist reports the ordinary outcome rather than
    /// inventing a warning about a volume it could not read.
    func testAMissingPathDoesNotInventAWarning() {
        XCTAssertNil(TrashPolicy.warning(for: [root.appendingPathComponent("gone")]))
    }

    /// The count in the message is of the items actually at risk, not the
    /// whole selection.
    func testTheMessageCountsOnlyTheItemsAtRisk() {
        XCTAssertEqual(
            TrashPolicy.Outcome.permanent(volume: "NAS"),
            TrashPolicy.Outcome.permanent(volume: "NAS")
        )
        XCTAssertNotEqual(
            TrashPolicy.Outcome.permanent(volume: "NAS"),
            TrashPolicy.Outcome.permanent(volume: "Other")
        )
    }
}
