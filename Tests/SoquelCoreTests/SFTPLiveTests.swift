import XCTest
@testable import SoquelCore

/// Talks to a real server. Skipped unless SOQUEL_SFTP_HOST is set.
final class SFTPLiveTests: XCTestCase {
    /// Exactly what the browser window does: connect with no password first,
    /// then with one, then list ".".
    func testTheBrowsersOwnSequence() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SOQUEL_SFTP_HOST"], let user = env["SOQUEL_SFTP_USER"] else {
            throw XCTSkip("no server configured")
        }
        let session = SFTPSession(location: .init(user: user, host: host, path: "."))

        // Step 1, as the window does: try without a password.
        var firstFailed = false
        do { try session.connect(password: nil) } catch {
            firstFailed = true
            print("LIVE: keyless attempt failed as expected: \(error)")
        }
        XCTAssertTrue(firstFailed, "server should refuse a keyless connect")

        // Step 2: with the password.
        try session.connect(password: env["SOQUEL_SFTP_PASSWORD"])
        print("LIVE: connected=\(session.isConnected)")

        // Step 3: list ".", which is what a bare user@host resolves to.
        let entries = try session.list(".")
        print("LIVE: list(\".\") returned \(entries.count) entries")
        for entry in entries { print("LIVE:   \(entry.isDirectory ? "dir " : "file") \(entry.name)") }
        XCTAssertGreaterThan(entries.count, 0, "listing the home directory returned nothing")
        session.disconnect()
    }
}
