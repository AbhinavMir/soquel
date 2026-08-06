import XCTest
@testable import SoquelCore

/// Talks to a real server. Skipped unless SOQUEL_SFTP_HOST is set, so it never
/// runs in an ordinary `swift test`.
final class SFTPLiveTests: XCTestCase {
    func testConnectAndList() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SOQUEL_SFTP_HOST"], let user = env["SOQUEL_SFTP_USER"] else {
            throw XCTSkip("no server configured")
        }
        let session = SFTPSession(location: .init(user: user, host: host))
        try session.connect(password: env["SOQUEL_SFTP_PASSWORD"])
        XCTAssertTrue(session.isConnected, "master connection should be up")

        let top = try session.list(".")
        print("LIVE: \(top.count) entries at top level")
        for entry in top { print("LIVE:   \(entry.isDirectory ? "dir " : "file") \(entry.name)") }

        let outgoing = try session.list("outgoing")
        print("LIVE: \(outgoing.count) entries in outgoing")
        for entry in outgoing.prefix(3) {
            print("LIVE:   \(entry.name) — \(entry.size) bytes — \(entry.modified.map(String.init(describing:)) ?? "no date")")
        }
        XCTAssertGreaterThan(outgoing.count, 0)
        XCTAssertTrue(outgoing.allSatisfy { !$0.name.isEmpty })
        session.disconnect()
    }
}
