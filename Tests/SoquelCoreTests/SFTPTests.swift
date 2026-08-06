import XCTest
@testable import SoquelCore

/// The listing lines here are what the server at the other end of the first
/// working connection actually sent, not invented ones.
final class SFTPTests: XCTestCase {
    func testParsesWhatARealServerSent() {
        let sample = """
        drwxr-xr-x    ? testclaims testclaims     4096 Jul 21 13:43 .
        drwxr-xr-x    ? root       root           4096 Jan  3  2025 ..
        -rw-r--r--    ? testclaims testclaims     1054 Jul 21 13:43 AMBRA911_837P_20260721_767777559.837
        -rw-r--r--    ? testclaims testclaims   169308 Jul 21 13:41 ambra911_outgoing_837.edi
        """
        let entries = SFTPSession.parse(listing: sample)
        // "." and ".." are the server's, not the user's.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "AMBRA911_837P_20260721_767777559.837")
        XCTAssertEqual(entries[0].size, 1054)
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertEqual(entries[1].size, 169308)
    }

    /// Splitting on whitespace loses everything after the first space in a
    /// name, which is the failure every hand-rolled ls parser starts with.
    func testANameWithSpacesSurvives() {
        let line = "drwxr-xr-x    2 me me     4096 Jul 14 14:25 sub folder with spaces"
        let entry = SFTPSession.parse(line: line)
        XCTAssertEqual(entry?.name, "sub folder with spaces")
        XCTAssertEqual(entry?.isDirectory, true)
    }

    /// A symlink is written "name -> target"; the link is what is listed.
    func testASymlinkKeepsItsOwnNameNotItsTarget() {
        let line = "lrwxrwxrwx    1 me me       11 Jul 14 14:25 link.txt -> plain.txt"
        let entry = SFTPSession.parse(line: line)
        XCTAssertEqual(entry?.name, "link.txt")
        XCTAssertEqual(entry?.isSymlink, true)
    }

    /// ls writes a clock for this year and a year for anything older.
    func testDatesWithAClockAndDatesWithAYear() {
        let now = SFTPSession.date(from: "Jan 3 2024")
        XCTAssertNotNil(now)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: now!), 2024)

        let reference = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6))!
        let recent = SFTPSession.date(from: "Jul 21 13:43", now: reference)
        XCTAssertEqual(calendar.component(.year, from: recent!), 2026)
        XCTAssertEqual(calendar.component(.hour, from: recent!), 13)
    }

    /// A date later than today has to belong to last year: ls omits the year
    /// for six months either side, so December reads as future in January.
    func testAFutureLookingDateIsLastYear() {
        let calendar = Calendar(identifier: .gregorian)
        let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let parsed = SFTPSession.date(from: "Dec 20 09:00", now: january)
        XCTAssertEqual(calendar.component(.year, from: parsed!), 2025)
    }

    /// A Unix socket path cannot exceed 104 bytes, and the caches directory is
    /// most of that before a name is added. This is why it lives in /tmp.
    func testTheControlSocketFitsInAUnixSocketPath() {
        let location = SFTPSession.Location(
            user: "someone-with-a-long-name", host: "a.very.long.hostname.example.com", port: 2222
        )
        let path = SFTPSession.controlPath(for: location)
        XCTAssertLessThan(path.utf8.count, 104)
    }

    /// Two destinations must not share one connection.
    func testDifferentDestinationsGetDifferentSockets() {
        let a = SFTPSession.controlPath(for: .init(user: "a", host: "h"))
        let b = SFTPSession.controlPath(for: .init(user: "b", host: "h"))
        let c = SFTPSession.controlPath(for: .init(user: "a", host: "h", port: 2222))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testURLsThatAreAndAreNotSFTP() {
        let full = SFTPSession.Location(url: URL(string: "sftp://me@host:2222/srv/data")!)
        XCTAssertEqual(full?.user, "me")
        XCTAssertEqual(full?.port, 2222)
        XCTAssertEqual(full?.path, "/srv/data")

        // No path means the folder the server drops you in, not the root.
        let bare = SFTPSession.Location(url: URL(string: "sftp://me@host")!)
        XCTAssertEqual(bare?.path, ".")

        XCTAssertNil(SFTPSession.Location(url: URL(string: "smb://me@host/share")!))
        XCTAssertNil(SFTPSession.Location(url: URL(string: "sftp://host/srv")!))
    }

    /// "Permission denied" should read as a wrong password, not as a stack of
    /// ssh diagnostics the user has to interpret.
    func testSshDiagnosticsBecomeSomethingReadable() {
        XCTAssertEqual(
            SFTPSession.failure(from: "me@host: Permission denied (publickey,password).", host: "host"),
            .authenticationFailed
        )
        XCTAssertEqual(
            SFTPSession.failure(from: "ssh: Could not resolve hostname nope", host: "nope"),
            .hostUnreachable("nope")
        )
    }

    func testQuotingAPathWithSpacesAndQuotes() {
        XCTAssertEqual(SFTPSession.quote("a b"), "\"a b\"")
        XCTAssertEqual(SFTPSession.quote("say \"hi\""), "\"say \\\"hi\\\"\"")
    }

    /// iCloud lives somewhere else entirely from every other provider, and
    /// both have to be found.
    func testFindsICloudAndTheFileProviders() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-cloud-\(UUID().uuidString)")
        let fm = FileManager.default
        for path in [
            "Library/Mobile Documents/com~apple~CloudDocs",
            "Library/CloudStorage/GoogleDrive-someone@gmail.com",
            "Library/CloudStorage/Dropbox",
        ] {
            try fm.createDirectory(
                at: home.appendingPathComponent(path), withIntermediateDirectories: true
            )
        }
        defer { try? fm.removeItem(at: home) }

        let names = CloudDrives.all(home: home).map(\.name)
        XCTAssertTrue(names.contains("iCloud Drive"))
        XCTAssertTrue(names.contains("Dropbox"))
        // The account is kept: two of the same service can be signed in.
        XCTAssertTrue(names.contains("Google Drive — someone@gmail.com"))
    }

    /// Nothing installed is not an error, it is an empty list.
    func testNoCloudDrivesIsNotAFailure() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-absent-\(UUID().uuidString)")
        XCTAssertEqual(CloudDrives.all(home: nowhere).count, 0)
    }

    /// The folders are written without spaces on disk.
    func testProviderNamesGetTheirSpacesBack() {
        XCTAssertEqual(CloudDrives.displayName(for: "GoogleDrive"), "Google Drive")
        XCTAssertEqual(CloudDrives.displayName(for: "OneDrive"), "One Drive")
        XCTAssertEqual(CloudDrives.displayName(for: "Box"), "Box")
    }

}
