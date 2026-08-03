import XCTest
@testable import SoquelCore

final class CommandRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func run(_ command: String) -> (output: String, status: Int32) {
        let runner = CommandRunner()
        var text = ""
        var status: Int32 = -99
        let done = expectation(description: command)
        runner.run(command, in: root) { event in
            switch event {
            case .output(let chunk): text += chunk
            case .finished(let code): status = code; done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        return (text, status)
    }

    func testACommandRunsInTheGivenFolder() {
        let result = run("pwd")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(root.lastPathComponent),
            "expected \(root.lastPathComponent) in \(result.output)"
        )
    }

    /// A non-zero exit is reported rather than swallowed.
    func testAFailingCommandReportsItsStatus() {
        XCTAssertEqual(run("exit 3").status, 3)
    }

    /// stderr goes to the same place as stdout, so an error message is not lost.
    func testStandardErrorIsShownToo() {
        XCTAssertTrue(run("echo oops >&2").output.contains("oops"))
    }

    /// Colour codes from a tool that emits them unconditionally would arrive
    /// as bracket-noise around every word.
    func testAnsiColourIsStripped() {
        XCTAssertEqual(CommandRunner.strip("\u{1B}[0;32mgreen\u{1B}[0m"), "green")
        XCTAssertEqual(CommandRunner.strip("plain"), "plain")
        XCTAssertEqual(CommandRunner.strip("\u{1B}]0;a title\u{07}after"), "after")
    }

    func testTheExitSummaryNamesWhatHappened() {
        XCTAssertEqual(CommandRunner.exitSummary(status: 0), "Done")
        XCTAssertEqual(CommandRunner.exitSummary(status: 130), "Interrupted")
        XCTAssertEqual(CommandRunner.exitSummary(status: 2), "Exited 2")
    }

    /// Up from an empty field gives the most recent; down past the newest
    /// clears rather than wrapping round to the oldest.
    func testHistoryWalksInBothDirectionsAndStops() {
        XCTAssertEqual(CommandPanelController.previousIndex(nil, count: 3), 2)
        XCTAssertEqual(CommandPanelController.previousIndex(2, count: 3), 1)
        XCTAssertEqual(CommandPanelController.previousIndex(0, count: 3), 0)

        XCTAssertEqual(CommandPanelController.nextIndex(0, count: 3), 1)
        XCTAssertNil(CommandPanelController.nextIndex(2, count: 3))
        XCTAssertNil(CommandPanelController.previousIndex(nil, count: 0))
    }
}
