import XCTest
@testable import SoquelCore

final class TransferQueueOrderTests: XCTestCase {
    /// A row lifted out of the list shifts everything after it up by one, so a
    /// drop index taken from the original list overshoots by one going down.
    func testADownwardMoveAccountsForTheRowBeingLifted() {
        XCTAssertEqual(TransferQueue.clampedDestination(from: 0, to: 2, count: 3), 1)
        XCTAssertEqual(TransferQueue.clampedDestination(from: 0, to: 3, count: 3), 2)
    }

    func testAnUpwardMoveIsUnchanged() {
        XCTAssertEqual(TransferQueue.clampedDestination(from: 2, to: 0, count: 3), 0)
        XCTAssertEqual(TransferQueue.clampedDestination(from: 2, to: 1, count: 3), 1)
    }

    /// Never past either end, whatever it is handed.
    func testTheDestinationIsAlwaysInRange() {
        for from in 0..<4 {
            for to in -2..<8 {
                let index = TransferQueue.clampedDestination(from: from, to: to, count: 4)
                XCTAssertTrue((0..<4).contains(index), "from=\(from) to=\(to) gave \(index)")
            }
        }
    }

    /// Only a waiting job reorders. A running one is already moving bytes.
    func testARunningJobDoesNotReorder() {
        let queue = TransferQueue.shared
        let before = queue.jobs
        defer { queue.clearFinished() }

        let job = TransferJob(
            sources: [URL(fileURLWithPath: "/soquel/a")],
            destination: URL(fileURLWithPath: "/soquel/dest"),
            isMove: false, now: Date()
        )
        queue.add(job)
        job.markStarted(totalBytes: 10, totalFiles: 1, now: Date())

        XCTAssertFalse(queue.move(id: job.id, to: 0))
        XCTAssertEqual(queue.jobs.count, before.count + 1)
        job.cancel()
    }

    /// Retrying when the failed files have since been moved away reports
    /// nothing retried rather than queueing a copy of paths that are not there.
    func testRetryingFilesThatAreGoneQueuesNothing() {
        let job = TransferJob(
            sources: [URL(fileURLWithPath: "/soquel/gone.txt")],
            destination: URL(fileURLWithPath: NSTemporaryDirectory()),
            isMove: false, now: Date()
        )
        job.recordFailure(URL(fileURLWithPath: "/soquel/gone.txt"), "no such file")
        XCTAssertTrue(TransferQueue.shared.retryFailures(of: job).isEmpty)
    }
}
