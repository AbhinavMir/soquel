import XCTest
@testable import SoquelCore

final class TransferJobTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(files: Int = 3, bytes: Int64 = 3000) -> TransferJob {
        let job = TransferJob(
            sources: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")],
            destination: URL(fileURLWithPath: "/tmp/dest"),
            isMove: false,
            now: epoch
        )
        job.markStarted(totalBytes: bytes, totalFiles: files, now: epoch)
        return job
    }

    func testTitleNamesTheOperationAndDestination() {
        let single = TransferJob(sources: [URL(fileURLWithPath: "/tmp/report.pdf")],
                                 destination: URL(fileURLWithPath: "/tmp/archive"),
                                 isMove: true, now: epoch)
        XCTAssertEqual(single.title, "Move report.pdf → archive")
        XCTAssertEqual(job().title, "Copy 2 items → dest")
    }

    func testProgressTracksBytes() {
        let job = job(bytes: 1000)
        XCTAssertEqual(job.fractionComplete, 0)
        job.advance(bytes: 250, file: "a", now: epoch.addingTimeInterval(1))
        XCTAssertEqual(job.fractionComplete, 0.25, accuracy: 0.001)
        job.advance(bytes: 750, file: "b", now: epoch.addingTimeInterval(2))
        XCTAssertEqual(job.fractionComplete, 1, accuracy: 0.001)
    }

    /// Copying more than measured must not report over 100%.
    func testProgressIsClamped() {
        let job = job(bytes: 100)
        job.advance(bytes: 500, file: "a", now: epoch.addingTimeInterval(1))
        XCTAssertEqual(job.fractionComplete, 1)
    }

    func testThroughputIsMeasuredOverElapsedTime() {
        let job = job(bytes: 10_000)
        job.advance(bytes: 2000, file: "a", now: epoch.addingTimeInterval(2))
        XCTAssertEqual(job.bytesPerSecond, 1000, accuracy: 1)
    }

    /// A number invented from too little data is worse than no number.
    func testNoEstimateUntilThereIsThroughput() {
        let job = job(bytes: 10_000)
        XCTAssertNil(job.secondsRemaining, "no estimate before anything has moved")

        job.advance(bytes: 1000, file: "a", now: epoch.addingTimeInterval(1))
        XCTAssertEqual(job.secondsRemaining ?? 0, 9, accuracy: 0.5)
    }

    func testNoEstimateWhenFinished() {
        let job = job(bytes: 1000)
        job.advance(bytes: 1000, file: "a", now: epoch.addingTimeInterval(1))
        XCTAssertNil(job.secondsRemaining)
    }

    /// One unreadable file must not abandon the rest of the job.
    func testFailuresAreRecordedAndTheJobContinues() {
        let job = job()
        job.recordFailure(URL(fileURLWithPath: "/tmp/bad"), "Permission denied")
        job.advance(bytes: 100, file: "next", now: epoch.addingTimeInterval(1))

        XCTAssertEqual(job.failures.count, 1)
        XCTAssertEqual(job.state, .running, "a failure does not stop the job")

        job.finish()
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.statusLine(formatter: ByteCountFormatter()).contains("failed"))
    }

    func testCleanJobFinishesAsDone() {
        let job = job()
        job.advance(bytes: 3000, file: "a", now: epoch.addingTimeInterval(1))
        job.finish()
        XCTAssertEqual(job.state, .finished)
    }

    func testPauseAndResume() {
        let job = job()
        job.pause()
        XCTAssertEqual(job.state, .paused)
        job.resume()
        XCTAssertEqual(job.state, .running)
    }

    /// Pausing something already finished must not revive it.
    func testPauseDoesNothingOnceFinished() {
        let job = job()
        job.finish()
        job.pause()
        XCTAssertEqual(job.state, .finished)
    }

    /// A cancelled job stays cancelled; finishing must not relabel it as done.
    func testCancelSticks() {
        let job = job()
        job.cancel()
        XCTAssertEqual(job.state, .cancelled)
        job.finish()
        XCTAssertEqual(job.state, .cancelled)
    }

    func testTimeIsDescribedCoarsely() {
        XCTAssertEqual(TransferJob.describe(seconds: 3), "a few seconds")
        XCTAssertEqual(TransferJob.describe(seconds: 45), "40 seconds")
        XCTAssertEqual(TransferJob.describe(seconds: 90), "2 minutes")
        XCTAssertEqual(TransferJob.describe(seconds: 60), "1 minute")
        XCTAssertTrue(TransferJob.describe(seconds: 7200).contains("hours"))
    }

    func testStatusLineNeverShowsABarePercentage() {
        let job = job(bytes: 2000)
        job.advance(bytes: 1000, file: "photo.jpg", now: epoch.addingTimeInterval(1))
        let line = job.statusLine(formatter: ByteCountFormatter())
        XCTAssertTrue(line.contains("photo.jpg"), "the line says what is being copied")
        XCTAssertTrue(line.contains("of"), "and how far through it is")
    }
}

final class TransferQueueTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TransferQueue.shared.cancelAll()
        TransferQueue.shared.clearFinished()
    }

    private func makeJob() -> TransferJob {
        TransferJob(sources: [URL(fileURLWithPath: "/tmp/a")],
                    destination: URL(fileURLWithPath: "/tmp/b"),
                    isMove: false, now: Date())
    }

    func testActiveCountTracksRunningJobs() {
        let job = makeJob()
        TransferQueue.shared.add(job)
        XCTAssertEqual(TransferQueue.shared.activeCount, 1)
        job.finish()
        XCTAssertEqual(TransferQueue.shared.activeCount, 0)
    }

    /// "Clear finished" must not take a running job with it.
    func testClearFinishedKeepsActiveJobs() {
        let done = makeJob()
        done.finish()
        let running = makeJob()
        TransferQueue.shared.add(done)
        TransferQueue.shared.add(running)

        TransferQueue.shared.clearFinished()
        XCTAssertEqual(TransferQueue.shared.jobs.count, 1)
        XCTAssertTrue(TransferQueue.shared.jobs.first?.isActive == true)
    }

    func testCancelAllStopsEverythingActive() {
        let a = makeJob(), b = makeJob()
        TransferQueue.shared.add(a)
        TransferQueue.shared.add(b)
        TransferQueue.shared.cancelAll()
        XCTAssertEqual(TransferQueue.shared.activeCount, 0)
    }

    func testAddingPostsAChange() {
        let expectation = expectation(forNotification: TransferQueue.changed, object: nil)
        TransferQueue.shared.add(makeJob())
        wait(for: [expectation], timeout: 2)
    }
}

final class TransferMeasureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMeasuresBytesAndFilesAcrossATree() throws {
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: dir.appendingPathComponent("a/one.bin"))
        try Data(repeating: 2, count: 2000).write(to: nested.appendingPathComponent("two.bin"))

        let measured = TransferQueue.measure([dir.appendingPathComponent("a")])
        XCTAssertEqual(measured.files, 2)
        XCTAssertEqual(measured.bytes, 3000)
    }

    func testMeasuresASingleFile() throws {
        let file = dir.appendingPathComponent("solo.bin")
        try Data(repeating: 9, count: 512).write(to: file)
        let measured = TransferQueue.measure([file])
        XCTAssertEqual(measured.bytes, 512)
        XCTAssertEqual(measured.files, 1)
    }

    /// A symlink is not the bytes it points at, and following one could count
    /// the same tree twice.
    func testSymlinksAreNotCounted() throws {
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("real.bin"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.bin"),
            withDestinationURL: dir.appendingPathComponent("real.bin")
        )
        XCTAssertEqual(TransferQueue.measure([dir]).files, 1)
    }
}
