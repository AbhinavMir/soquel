import Foundation
import XCTest
@testable import SoquelCore

/// Syncing onto a second volume — an external drive, a network mount, a disk
/// image — is the main use for folder compare, and it is the case a temporary
/// directory on the boot volume cannot serve.
final class SweepFoldercmpTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private var mount: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-sweep-foldercmp-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        for url in [left!, right!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let mount {
            // Deleting the tree while the image is still attached would reach
            // into the mounted volume, so a detach that will not take means
            // leaving the scratch files where they are.
            guard Self.shell("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) == 0 else {
                try super.tearDownWithError()
                return
            }
        }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ contents: String, to parent: URL, _ path: String,
                       modified: Date? = nil) throws -> URL {
        let url = parent.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    private static func shell(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A disk image is the only second volume a test can be sure of. Where one
    /// cannot be made — a sandbox without hdiutil, say — the cross-volume case
    /// is skipped rather than reported as a failure of the code under test.
    private func mountScratchVolume() throws -> URL {
        let image = root.appendingPathComponent("scratch.dmg")
        let point = root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
        try XCTSkipUnless(
            Self.shell("/usr/bin/hdiutil", [
                "create", "-size", "32m", "-fs", "APFS",
                "-volname", "SoquelSweep", "-quiet", image.path,
            ]) == 0,
            "no disk image could be created here"
        )
        try XCTSkipUnless(
            Self.shell("/usr/bin/hdiutil", [
                "attach", image.path, "-mountpoint", point.path,
                "-nobrowse", "-noverify", "-quiet",
            ]) == 0,
            "no disk image could be attached here"
        )
        mount = point
        return point
    }

    /// Names the old staging code left in the system temporary directory.
    private static func stagingLeftovers() -> [String] {
        let temporary = FileManager.default.temporaryDirectory.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? []
        return names.filter { $0.hasPrefix("soquel-sync-") }
    }

    private static func contains(_ name: String, under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator where url.lastPathComponent == name { return true }
        return false
    }

    /// The replacement used to be staged in the system temporary directory, on
    /// the boot volume, so replaceItemAt across to any other volume failed with
    /// POSIX 18 "Cross-device link". apply() stops at the first throw, so the
    /// second plan here never ran either.
    func testApplyReplacesAFileOnAnotherVolume() throws {
        let volume = try mountScratchVolume()
        let destination = volume.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try write("left version", to: left, "note.txt")
        try write("fresh", to: left, "then.txt")
        try write("right version", to: destination, "note.txt",
                  modified: Date(timeIntervalSince1970: 1))

        let entries = FolderCompare.compare(left: left, right: destination)
            .filter { $0.status.isDifference }
        let plans = FolderCompare.plan(entries, direction: .leftToRight,
                                       left: left, right: destination)
        // note.txt sorts first, so under the old code the overwrite threw
        // before then.txt was ever looked at.
        XCTAssertEqual(plans.map(\.relativePath), ["note.txt", "then.txt"])
        XCTAssertEqual(try FolderCompare.apply(plans), 2)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("note.txt"), encoding: .utf8),
            "left version"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("then.txt"), encoding: .utf8),
            "fresh", "the rest of the run was abandoned after the overwrite"
        )
        XCTAssertEqual(
            try String(contentsOf: left.appendingPathComponent("note.txt"), encoding: .utf8),
            "left version", "the source was consumed by the replacement"
        )
        XCTAssertFalse(
            Self.contains("note.txt", under: volume.appendingPathComponent(".TemporaryItems")),
            "the staged copy was left on the destination volume"
        )
    }

    /// Same-volume replacement still works, and the staging is not left behind.
    func testApplyLeavesNoStagingBehindOnSuccess() throws {
        try write("left version", to: left, "a.txt")
        try write("right version", to: right, "a.txt", modified: Date(timeIntervalSince1970: 1))

        let entries = FolderCompare.compare(left: left, right: right).filter { $0.status.isDifference }
        try FolderCompare.apply(
            FolderCompare.plan(entries, direction: .leftToRight, left: left, right: right)
        )

        XCTAssertEqual(
            try String(contentsOf: right.appendingPathComponent("a.txt"), encoding: .utf8),
            "left version"
        )
        XCTAssertEqual(Self.stagingLeftovers(), [], "a staging folder was left in the temporary directory")
    }

    /// The staging folder was made before the copy that throws, and nothing
    /// removed it, so every failed replacement left a full copy of the file on
    /// the boot volume.
    func testAFailedReplacementLeavesNoStagingBehind() throws {
        try write("right version", to: right, "a.txt")

        let plan = FolderCompare.Plan(
            source: left.appendingPathComponent("gone.txt"),
            destination: right.appendingPathComponent("a.txt"),
            relativePath: "a.txt",
            overwrites: true
        )
        XCTAssertThrowsError(try FolderCompare.apply([plan]))

        XCTAssertEqual(Self.stagingLeftovers(), [], "a staging folder was left in the temporary directory")
        XCTAssertEqual(
            try String(contentsOf: right.appendingPathComponent("a.txt"), encoding: .utf8),
            "right version", "a failed replacement destroyed the destination"
        )
    }
}
