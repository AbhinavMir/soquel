import XCTest
@testable import SoquelCore

final class RemoteLocationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Settings.removeObject(forKey: "recentServers")
    }

    override func tearDown() {
        Settings.removeObject(forKey: "recentServers")
        super.tearDown()
    }

    private func address(_ text: String) -> RemoteLocations.Address? {
        try? RemoteLocations.parse(text).get()
    }

    private func failure(_ text: String) -> RemoteLocations.AddressError? {
        switch RemoteLocations.parse(text) {
        case .failure(let error): return error
        case .success: return nil
        }
    }

    // MARK: - Parsing

    func testASimpleShare() {
        let parsed = address("smb://fileserver/projects")
        XCTAssertEqual(parsed?.scheme, .smb)
        XCTAssertEqual(parsed?.host, "fileserver")
        XCTAssertEqual(parsed?.path, "/projects")
        XCTAssertNil(parsed?.user)
    }

    func testUserAndPort() {
        let parsed = address("afp://ada@nas.local:548/media")
        XCTAssertEqual(parsed?.user, "ada")
        XCTAssertEqual(parsed?.port, 548)
        XCTAssertEqual(parsed?.host, "nas.local")
    }

    func testEveryNativeSchemeIsAccepted() {
        for scheme in ["smb", "afp", "nfs", "http", "https", "ftp"] {
            XCTAssertEqual(address("\(scheme)://host/share")?.scheme.rawValue, scheme)
        }
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(address("SMB://host/share")?.scheme, .smb)
    }

    /// A bare hostname could be any of five protocols, and choosing one would
    /// silently connect the user to the wrong thing.
    func testABareHostnameIsRejected() {
        XCTAssertEqual(failure("fileserver/projects"), .missingScheme)
    }

    func testAnUnknownSchemeIsRejectedByName() {
        XCTAssertEqual(failure("gopher://host/thing"), .unknownScheme("gopher"))
    }

    func testEmptyInput() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   "), .empty)
    }

    func testASchemeWithNoHost() {
        XCTAssertEqual(failure("smb:///share"), .missingHost)
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(address("  smb://host/share  ")?.host, "host")
    }

    // MARK: - Address properties

    func testDisplayNameIsTheShare() {
        XCTAssertEqual(address("smb://server/projects")?.displayName, "projects")
    }

    func testDisplayNameFallsBackToTheHost() {
        XCTAssertEqual(address("smb://server")?.displayName, "server")
        XCTAssertEqual(address("smb://server/")?.displayName, "server")
    }

    func testURLRoundTrip() {
        XCTAssertEqual(address("smb://server/projects")?.url?.absoluteString, "smb://server/projects")
        XCTAssertEqual(address("afp://ada@nas:548/media")?.url?.absoluteString, "afp://ada@nas:548/media")
    }

    func testFTPIsFlaggedReadOnly() {
        XCTAssertTrue(RemoteLocations.Scheme.ftp.isReadOnly)
        XCTAssertFalse(RemoteLocations.Scheme.smb.isReadOnly)
    }

    // MARK: - What this machine can mount

    func testSFTPIsNotNative() {
        XCTAssertFalse(RemoteLocations.Scheme.sftp.isNative)
        for scheme in RemoteLocations.Scheme.allCases where scheme != .sftp {
            XCTAssertTrue(scheme.isNative, "\(scheme) should be mountable by macOS")
        }
    }

    /// This used to assert the answer was "go and install macFUSE". It is not
    /// any more: SFTP opens in a browser window over the ssh already on the
    /// system, so nothing is refused and nothing has to be installed. The
    /// error stays for any other scheme that has no mount helper.
    func testSFTPWithoutSSHFSNoLongerTellsAnyoneToInstallAnything() throws {
        let sftp = try XCTUnwrap(address("sftp://host/home"))
        let problem = RemoteLocations.check(sftp, sshfsPath: nil)
        XCTAssertFalse(
            problem?.localizedDescription.contains("macFUSE") ?? false,
            "nothing needs installing for SFTP any more"
        )
    }

    func testSFTPWithSSHFSIsAllowed() throws {
        let sftp = try XCTUnwrap(address("sftp://host/home"))
        XCTAssertNil(RemoteLocations.check(sftp, sshfsPath: "/opt/homebrew/bin/sshfs"))
    }

    func testNativeSchemesNeverNeedFUSE() throws {
        let smb = try XCTUnwrap(address("smb://host/share"))
        XCTAssertNil(RemoteLocations.check(smb, sshfsPath: nil))
    }

    // MARK: - Errors

    func testMountErrorsAreExplainedRatherThanNumbered() throws {
        let smb = try XCTUnwrap(address("smb://fileserver/share"))
        XCTAssertTrue(
            RemoteLocations.mountError(status: Int32(EACCES), address: smb)
                .localizedDescription.contains("credentials")
        )
        XCTAssertTrue(
            RemoteLocations.mountError(status: Int32(ETIMEDOUT), address: smb)
                .localizedDescription.contains("did not answer")
        )
        XCTAssertTrue(
            RemoteLocations.mountError(status: Int32(EHOSTUNREACH), address: smb)
                .localizedDescription.contains("could not be reached")
        )
    }

    /// An unrecognised status still names the host and the number, so it can be
    /// looked up rather than being a dead end.
    func testAnUnknownStatusStillSaysSomethingUseful() throws {
        let smb = try XCTUnwrap(address("smb://fileserver/share"))
        let message = RemoteLocations.mountError(status: 12345, address: smb).localizedDescription
        XCTAssertTrue(message.contains("fileserver"))
        XCTAssertTrue(message.contains("12345"))
    }

    // MARK: - Recents

    func testRecentsAreMostRecentFirst() throws {
        RemoteLocations.remember(try XCTUnwrap(address("smb://a/one")))
        RemoteLocations.remember(try XCTUnwrap(address("smb://b/two")))
        XCTAssertEqual(RemoteLocations.recents, ["smb://b/two", "smb://a/one"])
    }

    func testReconnectingMovesAnAddressToTheTop() throws {
        RemoteLocations.remember(try XCTUnwrap(address("smb://a/one")))
        RemoteLocations.remember(try XCTUnwrap(address("smb://b/two")))
        RemoteLocations.remember(try XCTUnwrap(address("smb://a/one")))
        XCTAssertEqual(RemoteLocations.recents, ["smb://a/one", "smb://b/two"])
    }

    func testRecentsAreCapped() throws {
        for index in 0...(RemoteLocations.recentLimit + 5) {
            RemoteLocations.remember(try XCTUnwrap(address("smb://host/share\(index)")))
        }
        XCTAssertEqual(RemoteLocations.recents.count, RemoteLocations.recentLimit)
    }

    /// A password typed into an address must never reach the recents list.
    func testRecentsNeverHoldAPassword() throws {
        let parsed = try XCTUnwrap(address("smb://ada:hunter2@host/share"))
        RemoteLocations.remember(parsed)
        for entry in RemoteLocations.recents {
            XCTAssertFalse(entry.contains("hunter2"))
        }
    }

    func testForgettingRecents() throws {
        RemoteLocations.remember(try XCTUnwrap(address("smb://a/one")))
        RemoteLocations.forgetRecents()
        XCTAssertTrue(RemoteLocations.recents.isEmpty)
    }

    func testChangeIsAnnounced() throws {
        expectation(forNotification: .soquelServersChanged, object: nil)
        RemoteLocations.remember(try XCTUnwrap(address("smb://a/one")))
        waitForExpectations(timeout: 2)
    }
}
