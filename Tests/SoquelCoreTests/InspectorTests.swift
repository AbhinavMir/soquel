import XCTest
import CryptoKit
@testable import SoquelCore

final class InspectorTests: XCTestCase {
    func testPermissionStringMatchesLs() {
        XCTAssertEqual(InspectorView.describe(mode: 0o755), "rwxr-xr-x (755)")
        XCTAssertEqual(InspectorView.describe(mode: 0o644), "rw-r--r-- (644)")
        XCTAssertEqual(InspectorView.describe(mode: 0o600), "rw------- (600)")
        XCTAssertEqual(InspectorView.describe(mode: 0o777), "rwxrwxrwx (777)")
        XCTAssertEqual(InspectorView.describe(mode: 0o000), "--------- (000)")
    }

    /// The high bits (setuid, directory flag) come in with st_mode and must not
    /// leak into the octal.
    func testPermissionStringIgnoresFileTypeBits() {
        XCTAssertEqual(InspectorView.describe(mode: 0o040755), "rwxr-xr-x (755)")
    }

    func testChecksumMatchesCryptoKitOneShot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sum-\(UUID().uuidString)")
        // Larger than the 1 MB read chunk, so the streaming path is exercised.
        let data = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Checksum.sha256(of: url), expected)
    }

    func testChecksumOfEmptyFileIsTheEmptyDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Checksum.sha256(of: url),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testChecksumOfMissingFileIsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/soquel/\(UUID().uuidString)")
        XCTAssertNil(Checksum.sha256(of: url))
    }

    func testExtendedAttributeNamesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-xattr-\(UUID().uuidString)")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // macOS stamps com.apple.provenance on new files by itself, so this
        // checks for the attribute we set rather than the whole list.
        XCTAssertFalse(url.extendedAttributeNames().contains("com.soquel.test"))
        let value = Array("tagged".utf8)
        XCTAssertEqual(setxattr(url.path, "com.soquel.test", value, value.count, 0, 0), 0)
        XCTAssertTrue(url.extendedAttributeNames().contains("com.soquel.test"))
    }
}
