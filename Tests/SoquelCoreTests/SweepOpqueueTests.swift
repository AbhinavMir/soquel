import XCTest
@testable import SoquelCore

/// The copy loop reports a failed file by calling `recordFailure` and then
/// `advance(bytes: 0, file:)`, so that the panel keeps naming the file it was
/// working on. These cover the count that summary is built from.
final class TransferJobFailureCountTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(files: Int, bytes: Int64 = 10_000) -> TransferJob {
        let job = TransferJob(
            sources: [URL(fileURLWithPath: "/tmp/a")],
            destination: URL(fileURLWithPath: "/tmp/dest"),
            isMove: false,
            now: epoch
        )
        job.markStarted(totalBytes: bytes, totalFiles: files, now: epoch)
        return job
    }

    /// Reports the file the way the copy loop does: recorded, then advanced
    /// with no bytes so the panel still names it.
    private func reportFailure(_ job: TransferJob, _ name: String, at offset: TimeInterval) {
        job.recordFailure(URL(fileURLWithPath: "/tmp/src/\(name)"), "Permission denied")
        job.advance(bytes: 0, file: name, now: epoch.addingTimeInterval(offset))
    }

    func testAFailedFileIsNotCountedAsCopied() {
        let job = job(files: 1)
        reportFailure(job, "report.pdf", at: 1)

        XCTAssertEqual(job.filesCopied, 0)
        XCTAssertEqual(job.failures.count, 1)
        XCTAssertEqual(job.currentFile, "report.pdf", "the panel still names the file it was on")
    }

    /// A job where nothing arrived must not tell the user ten files arrived —
    /// that is a summary they could act on by deleting the sources.
    func testAJobWhereEverythingFailedReportsNothingCopied() {
        let job = job(files: 10)
        for index in 0..<10 { reportFailure(job, "file\(index).bin", at: Double(index + 1)) }
        job.finish()

        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.filesCopied, 0)
        XCTAssertEqual(
            job.statusLine(formatter: ByteCountFormatter()),
            "10 of 10 failed — 0 copied"
        )
    }

    func testMixedJobCountsOnlyTheFilesThatArrived() {
        let job = job(files: 3)
        job.advance(bytes: 1000, file: "one.bin", now: epoch.addingTimeInterval(1))
        reportFailure(job, "two.bin", at: 2)
        job.advance(bytes: 2000, file: "three.bin", now: epoch.addingTimeInterval(3))
        job.finish()

        XCTAssertEqual(job.filesCopied, 2)
        XCTAssertEqual(job.bytesCopied, 3000, "a failure contributes no bytes either")
        XCTAssertEqual(
            job.statusLine(formatter: ByteCountFormatter()),
            "1 of 3 failed — 2 copied"
        )
    }

    /// Only the report of the failure itself is discounted. The file copied
    /// after it is a file that arrived.
    func testTheFileAfterAFailureStillCounts() {
        let job = job(files: 2)
        job.recordFailure(URL(fileURLWithPath: "/tmp/src/bad.bin"), "Permission denied")
        job.advance(bytes: 500, file: "good.bin", now: epoch.addingTimeInterval(1))

        XCTAssertEqual(job.filesCopied, 1)
    }

    /// Two sources can carry the same name into one destination. The one that
    /// succeeds must still be counted, even though a file of that name failed
    /// earlier in the job.
    func testALaterFileSharingAFailedNameStillCounts() {
        let job = job(files: 2)
        reportFailure(job, "notes.txt", at: 1)
        job.advance(bytes: 800, file: "notes.txt", now: epoch.addingTimeInterval(2))

        XCTAssertEqual(job.filesCopied, 1)
        XCTAssertEqual(job.failures.count, 1)
    }

    /// A run of failures leaves nothing behind that would swallow the next
    /// successful file.
    func testConsecutiveFailuresDoNotAccumulate() {
        let job = job(files: 3)
        reportFailure(job, "a.bin", at: 1)
        reportFailure(job, "b.bin", at: 2)
        job.advance(bytes: 400, file: "c.bin", now: epoch.addingTimeInterval(3))

        XCTAssertEqual(job.filesCopied, 1)
        XCTAssertEqual(job.failures.count, 2)
    }

    /// Progress ticks that name no file are byte updates within one file, not
    /// another file arriving.
    func testAnUnnamedAdvanceCountsNoFile() {
        let job = job(files: 1)
        job.advance(bytes: 250, file: nil, now: epoch.addingTimeInterval(1))
        job.advance(bytes: 250, file: nil, now: epoch.addingTimeInterval(2))

        XCTAssertEqual(job.filesCopied, 0)
        XCTAssertEqual(job.bytesCopied, 500)
    }
}
