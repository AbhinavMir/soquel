import AppKit
import XCTest
@testable import SoquelCore

final class TagsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func file(_ name: String = "f.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testATagSurvivesAWriteAndRead() throws {
        let url = try file()
        XCTAssertNil(Tags.write(["Red"], to: url))
        XCTAssertEqual(Tags.read(url), ["Red"])
    }

    func testTogglingAddsThenRemoves() throws {
        let url = try file()
        XCTAssertNil(Tags.toggle("Blue", on: url))
        XCTAssertEqual(Tags.read(url), ["Blue"])
        XCTAssertNil(Tags.toggle("Blue", on: url))
        XCTAssertTrue(Tags.read(url).isEmpty)
    }

    func testClearingRemovesEveryTag() throws {
        let url = try file()
        Tags.write(["Red", "Green"], to: url)
        Tags.write([], to: url)
        XCTAssertTrue(Tags.read(url).isEmpty)
    }

    /// One colour, not a blend. A file tagged Red and Blue draws red.
    func testTheFirstColouredTagDecidesTheRowTint() {
        XCTAssertEqual(Tags.rowTint(for: ["Red", "Blue"]), NSColor.systemRed)
        XCTAssertNil(Tags.rowTint(for: []))
    }

    /// A tag with a name nobody assigned a colour to is still a tag.
    func testAnInventedTagNameStillTintsTheRow() {
        XCTAssertEqual(Tags.rowTint(for: ["Invoices"]), NSColor.systemGray)
    }

    /// exFAT has no extended attributes, so a tag written there is gone on the
    /// next mount. Saying nothing is how the standing complaint happens.
    func testFormatsWithoutExtendedAttributesAreFlagged() {
        XCTAssertTrue(Tags.formatDropsTags("exfat"))
        XCTAssertTrue(Tags.formatDropsTags("ExFAT"))
        XCTAssertTrue(Tags.formatDropsTags("msdos"))
        XCTAssertFalse(Tags.formatDropsTags("apfs"))
        XCTAssertFalse(Tags.formatDropsTags("hfs"))
        XCTAssertFalse(Tags.formatDropsTags(nil))
    }

    /// The local disk is APFS, so tagging here warns about nothing.
    func testNoWarningOnAVolumeThatKeepsTags() throws {
        XCTAssertNil(Tags.warning(for: try file()))
    }
}
