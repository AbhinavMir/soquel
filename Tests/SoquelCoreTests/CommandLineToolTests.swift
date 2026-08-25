import Foundation
import XCTest
@testable import SoquelCore

final class CommandLineToolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLauncherOpensSoquelAndForwardsEveryPath() {
        XCTAssertEqual(
            CommandLineTool.launcher,
            "#!/bin/sh\nexec /usr/bin/open -b app.soquel.Soquel -- \"$@\"\n"
        )
    }

    func testWritingTheCommandMakesAnExecutableInstalledLauncher() throws {
        let command = directory.appendingPathComponent("nested/bin/soquel")
        try CommandLineTool.write(at: command)

        XCTAssertTrue(CommandLineTool.isInstalled(at: command))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path))
    }

    func testAStaleOrDifferentCommandIsNotReportedAsInstalled() throws {
        let command = directory.appendingPathComponent("soquel")
        try "#!/bin/sh\necho something-else\n".write(
            to: command, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: command.path
        )

        XCTAssertTrue(CommandLineTool.exists(at: command))
        XCTAssertFalse(CommandLineTool.isInstalled(at: command))
    }

    func testACommandWithoutExecutePermissionIsNotReportedAsInstalled() throws {
        let command = directory.appendingPathComponent("soquel")
        try CommandLineTool.launcher.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: command.path
        )

        XCTAssertFalse(CommandLineTool.isInstalled(at: command))
    }
}
