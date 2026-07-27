import XCTest
@testable import SoquelCore

final class PathTests: XCTestCase {
    /// URL.deletingLastPathComponent() appends ".." at "/", which once hung the
    /// app at launch. The walk must terminate.
    func testParentWalkTerminatesAtRoot() {
        XCTAssertNil(parentDirectoryURL(of: URL(fileURLWithPath: "/")))

        var cursor: URL? = URL(fileURLWithPath: "/usr/local/share")
        var visited: [String] = []
        var steps = 0
        while let current = cursor {
            visited.append(current.path)
            cursor = parentDirectoryURL(of: current)
            steps += 1
            XCTAssertLessThan(steps, 100, "parent walk did not terminate")
        }
        XCTAssertEqual(visited, ["/usr/local/share", "/usr/local", "/usr", "/"])
    }

    func testParentOfDirectoryWithTrailingSlash() {
        let url = URL(fileURLWithPath: "/usr/local/", isDirectory: true)
        XCTAssertEqual(parentDirectoryURL(of: url)?.path, "/usr")
    }

    func testPathFormats() {
        let url = URL(fileURLWithPath: "/Users/abhinav/Projects/My App/src/main.swift")
        XCTAssertEqual(PathFormat.absolute.string(for: url), "/Users/abhinav/Projects/My App/src/main.swift")
        XCTAssertEqual(PathFormat.filename.string(for: url), "main.swift")
        XCTAssertEqual(PathFormat.filenameNoExtension.string(for: url), "main")
        XCTAssertEqual(PathFormat.parentDirectory.string(for: url), "/Users/abhinav/Projects/My App/src")
        XCTAssertEqual(PathFormat.shellEscaped.string(for: url),
                       "'/Users/abhinav/Projects/My App/src/main.swift'")
    }

    /// A single quote in a filename must not break out of the quoted string.
    func testShellEscapingHandlesQuotes() {
        let url = URL(fileURLWithPath: "/tmp/it's a file.txt")
        XCTAssertEqual(PathFormat.shellEscaped.string(for: url), "'/tmp/it'\\''s a file.txt'")
    }

    func testParentDirectoryFormatAtRoot() {
        XCTAssertEqual(PathFormat.parentDirectory.string(for: URL(fileURLWithPath: "/")), "/")
    }

    func testRelativePath() {
        let base = URL(fileURLWithPath: "/Users/a/proj")
        XCTAssertEqual(relativePath(of: URL(fileURLWithPath: "/Users/a/proj/src/main.swift"), from: base),
                       "src/main.swift")
        XCTAssertEqual(relativePath(of: URL(fileURLWithPath: "/Users/a/other/x.txt"), from: base),
                       "../other/x.txt")
        XCTAssertEqual(relativePath(of: base, from: base), ".")
    }
}
