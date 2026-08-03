import AppKit
import XCTest
@testable import SoquelCore

final class ThemeSharingTests: XCTestCase {
    // MARK: - Reading the address

    /// Whichever form was to hand: the address bar, the Raw button, or the id.
    func testEveryFormOfGistAddressIsAccepted() {
        let id = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
        let inputs = [
            id,
            "https://gist.github.com/someone/\(id)",
            "https://gist.github.com/\(id)",
            "https://gist.githubusercontent.com/someone/\(id)/raw/abc/theme.json",
            "  https://gist.github.com/someone/\(id)  ",
        ]
        for input in inputs {
            XCTAssertEqual(ThemeSharing.gistID(from: input), id, input)
        }
    }

    /// Anything else is refused rather than turned into a request.
    func testNonGistAddressesAreRefused() {
        for input in ["", "hello", "https://example.com/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
                      "https://gist.github.com/someone/short"] {
            XCTAssertNil(ThemeSharing.gistID(from: input), input)
        }
    }

    // MARK: - Reading the gist

    private func gist(_ files: [String: String]) -> Data {
        let payload = ["files": files.mapValues { ["content": $0] }]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private let theme = ##"{"light":{"accent":"#FF0000"},"dark":{"accent":"#00FF00"}}"##

    func testTheThemeIsReadOutOfTheGist() throws {
        let result = ThemeSharing.theme(fromGist: gist(["theme.json": theme]))
        let config = try result.get()
        XCTAssertEqual(config.light["accent"], "#FF0000")
        XCTAssertEqual(config.dark["accent"], "#00FF00")
    }

    /// A gist with a README alongside still works.
    func testOtherFilesAreSkipped() throws {
        let data = gist(["README.md": "# my theme", "theme.json": theme])
        XCTAssertEqual(try ThemeSharing.theme(fromGist: data).get().light["accent"], "#FF0000")
    }

    func testAGistWithNoJSONSaysSo() {
        let result = ThemeSharing.theme(fromGist: gist(["README.md": "nothing here"]))
        XCTAssertEqual(result, .failure(.noJSON))
    }

    /// Valid JSON that is not a theme decodes to an empty config, which would
    /// "apply" and change nothing while claiming it worked.
    func testJSONThatIsNotAThemeIsRefused() {
        let result = ThemeSharing.theme(fromGist: gist(["data.json": #"{"hello":"world"}"#]))
        XCTAssertEqual(result, .failure(.unreadable))
    }

    func testGarbageIsRefused() {
        XCTAssertEqual(ThemeSharing.theme(fromGist: Data("not json".utf8)), .failure(.unreadable))
    }

    // MARK: - What a shared theme may carry

    /// A background is a path on the sender's disk. It either does not exist
    /// here or points at a different picture of yours.
    func testADownloadedThemeCannotBringABackgroundImage() throws {
        let withImage = ##"""
        {"light":{"accent":"#FF0000"},"dark":{},
         "background":{"imagePath":"/Users/someone/secret.png","opacity":1,
                       "fit":"fill","includeSidebar":true}}
        """##
        let config = try ThemeSharing.theme(fromGist: gist(["theme.json": withImage])).get()
        XCTAssertNil(config.background, "someone else's path must not come across")
    }

    // MARK: - Sharing yours

    /// What you paste into a gist is the same file you already have.
    func testTheExportIsAThemeThatCanBeReadBack() throws {
        let text = ThemeSharing.exportText()
        XCTAssertTrue(text.contains("\"light\""), text)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testTheSummaryCountsBothSides() {
        let config = ThemeConfig(light: ["accent": "#FFF", "chrome": "#EEE"], dark: ["accent": "#000"])
        XCTAssertEqual(ThemeSharing.summary(config), "2 light colours, 1 dark colour")
    }
}
