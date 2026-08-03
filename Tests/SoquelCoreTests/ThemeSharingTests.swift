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

    /// An absolute path is the sender's disk. It either does not exist here or
    /// points at a different picture of yours.
    func testAnAbsolutePathIsRefused() throws {
        let withImage = ##"""
        {"light":{"accent":"#FF0000"},"dark":{},
         "background":{"imagePath":"/Users/someone/secret.png","opacity":1,
                       "fit":"fill","includeSidebar":true}}
        """##
        let config = try ThemeSharing.theme(fromGist: gist(["theme.json": withImage])).get()
        XCTAssertNil(config.background, "someone else's path must not come across")
    }

    /// A relative path names a file inside the theme's own repository, which is
    /// the reason to put a theme in a repository rather than a gist.
    func testARelativePathIsKept() throws {
        let withImage = ##"""
        {"light":{"accent":"#FF0000"},"dark":{},
         "background":{"imagePath":"wallpaper.png","opacity":0.3,
                       "fit":"fill","includeSidebar":false}}
        """##
        let config = try ThemeSharing.theme(fromGist: gist(["theme.json": withImage])).get()
        XCTAssertEqual(config.background?.imagePath, "wallpaper.png")
    }

    /// A theme may bring its own picture. It may not read yours, and it may not
    /// pull one from somewhere else.
    func testOnlyPathsInsideTheRepositoryAreAllowed() {
        for good in ["wallpaper.png", "images/bg.jpg", "a/b/c.png"] {
            XCTAssertTrue(ThemeSharing.isRelative(good), good)
        }
        for bad in ["/Users/someone/x.png", "~/Pictures/x.png", "../../etc/passwd",
                    "https://example.com/x.png", "images/../../x.png", ""] {
            XCTAssertFalse(ThemeSharing.isRelative(bad), bad)
        }
    }

    /// The picture comes from the same repository, branch and all.
    func testTheImageURLSitsBesideTheThemeFile() {
        let source = ThemeSharing.Source.repository(owner: "a", name: "b", ref: "v2")
        XCTAssertEqual(source.url(forRelative: "images/bg.png")?.absoluteString,
                       "https://raw.githubusercontent.com/a/b/v2/images/bg.png")
        XCTAssertEqual(source.url(forRelative: "./bg.png")?.absoluteString,
                       "https://raw.githubusercontent.com/a/b/v2/bg.png")
    }

    /// A gist is a flat list of text files and has nowhere to keep a picture.
    func testAGistHasNoPlaceToPutAnImage() {
        XCTAssertNil(ThemeSharing.Source.gist("abc").url(forRelative: "bg.png"))
    }

    /// Two themes cannot overwrite each other's background.
    func testEachRepositoryKeepsItsPictureSeparately() {
        let one = ThemeSharing.mediaDirectory(for: .repository(owner: "a", name: "b", ref: "HEAD"))
        let two = ThemeSharing.mediaDirectory(for: .repository(owner: "c", name: "d", ref: "HEAD"))
        XCTAssertNotNil(one)
        XCTAssertNotEqual(one, two)
        XCTAssertNil(ThemeSharing.mediaDirectory(for: .gist("abc")))
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

final class ThemeRepositoryTests: XCTestCase {
    private func repo(_ input: String) -> ThemeSharing.Source? {
        ThemeSharing.source(from: input)
    }

    /// However the address was copied: the page, the clone URL, or by hand.
    func testEveryFormOfRepositoryAddressIsAccepted() {
        let expected = ThemeSharing.Source.repository(owner: "someone", name: "my-theme", ref: "HEAD")
        for input in [
            "someone/my-theme",
            "https://github.com/someone/my-theme",
            "https://github.com/someone/my-theme.git",
            "git@github.com:someone/my-theme.git",
            "  https://github.com/someone/my-theme  ",
        ] {
            XCTAssertEqual(repo(input), expected, input)
        }
    }

    /// A branch or tag, so a theme can be tried before it is merged.
    func testABranchCanBeNamed() {
        XCTAssertEqual(repo("someone/my-theme#dark-mode"),
                       .repository(owner: "someone", name: "my-theme", ref: "dark-mode"))
        XCTAssertEqual(repo("https://github.com/someone/my-theme/tree/v2"),
                       .repository(owner: "someone", name: "my-theme", ref: "v2"))
    }

    /// A gist id is hex and a repository is owner/name, so the two never
    /// collide.
    func testAGistIsStillReadAsAGist() {
        let id = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
        XCTAssertEqual(repo("https://gist.github.com/someone/\(id)"), .gist(id))
        XCTAssertEqual(repo(id), .gist(id))
    }

    /// Somewhere else entirely is refused rather than turned into a request.
    func testOtherHostsAreRefused() {
        for input in ["https://example.com/someone/my-theme", "https://gitlab.com/a/b",
                      "git@gitlab.com:a/b.git", "just-a-word", ""] {
            XCTAssertNil(repo(input), input)
        }
    }

    /// theme.json at the top level, which is the one format.
    func testTheRepositoryURLPointsAtTheThemeFile() {
        let url = repo("someone/my-theme")?.url?.absoluteString
        XCTAssertEqual(url, "https://raw.githubusercontent.com/someone/my-theme/HEAD/theme.json")
    }

    func testTheBranchReachesTheURL() {
        let url = repo("someone/my-theme#v2")?.url?.absoluteString
        XCTAssertEqual(url, "https://raw.githubusercontent.com/someone/my-theme/v2/theme.json")
    }
}
