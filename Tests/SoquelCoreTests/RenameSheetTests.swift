import XCTest
@testable import SoquelCore

/// The rename path shared by the inline editor and the sheet.
final class RenameValidationTests: XCTestCase {
    func testNamesWithPathSeparatorsAreRejected() {
        XCTAssertNotNil(validateFileName("a/b"))
        XCTAssertNotNil(validateFileName("a:b"))
    }

    func testEmptyAndWhitespaceNamesAreRejected() {
        XCTAssertNotNil(validateFileName(""))
        XCTAssertNotNil(validateFileName("   "))
    }

    func testOrdinaryNamesAreAccepted() {
        XCTAssertNil(validateFileName("notes.txt"))
        XCTAssertNil(validateFileName("Some Folder"))
        XCTAssertNil(validateFileName(".hidden"))
    }
}
