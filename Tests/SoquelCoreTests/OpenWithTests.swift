import XCTest
import UniformTypeIdentifiers
@testable import SoquelCore

final class OpenWithTests: XCTestCase {
    private func temporaryFile(extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-openwith-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testContentTypeComesFromTheExtension() throws {
        let url = try temporaryFile(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(OpenWith.contentType(of: url), .png)
    }

    func testTypeDescriptionFallsBackToTheExtension() {
        // A file that does not exist has no resource values to read, so the
        // menu title must still say something usable.
        let url = URL(fileURLWithPath: "/nonexistent/thing.wibble")
        XCTAssertEqual(OpenWith.typeDescription(of: url), ".wibble files")
    }

    func testTypeDescriptionForAnExtensionlessMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/thing")
        XCTAssertEqual(OpenWith.typeDescription(of: url), "this kind of file")
    }

    func testCandidatesAreDeduplicatedByBundle() throws {
        let url = try temporaryFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let candidates = OpenWith.candidates(for: url)
        let identifiers = candidates.map { Bundle(url: $0)?.bundleIdentifier ?? $0.path }
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    /// Every machine has something registered for plain text, so an empty list
    /// here means the lookup itself is broken.
    func testTextFilesHaveAtLeastOneCandidate() throws {
        let url = try temporaryFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(OpenWith.candidates(for: url).isEmpty)
        XCTAssertNotNil(OpenWith.defaultApplication(for: url))
    }

    func testDisplayNameDropsTheAppExtension() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(OpenWith.displayName(of: finder), "Finder")
    }
}

final class ToolbarGroupingTests: XCTestCase {
    func testViewModesShareOneGroup() {
        let modes = ["listView", "iconView", "columnView"].compactMap { ToolbarCatalogue.action(id: $0) }
        XCTAssertEqual(modes.count, 3)
        XCTAssertEqual(Set(modes.map(\.group)), ["viewMode"])
    }

    /// Grouped actions must sit next to each other in the catalogue, because
    /// the bar only merges a run of consecutive members into one pill.
    func testGroupedActionsAreContiguousInTheCatalogue() {
        var seenGroups: [String] = []
        var previous: String?
        for action in ToolbarCatalogue.all {
            guard let group = action.group else { previous = nil; continue }
            if group != previous {
                XCTAssertFalse(seenGroups.contains(group), "\(group) is split across the catalogue")
                seenGroups.append(group)
            }
            previous = group
        }
    }

    func testTogglesOutsideAGroupStayPlainButtons() {
        XCTAssertNil(ToolbarCatalogue.action(id: "hidden")?.group)
        XCTAssertNil(ToolbarCatalogue.action(id: "inspector")?.group)
    }
}
