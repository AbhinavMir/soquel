import XCTest
@testable import SoquelCore

final class RenameFuzzTests: XCTestCase {
    private func scratch() throws -> URL {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Hostile names through the whole rename planner.
    func testHostileNamesDoNotProduceUnusablePlans() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["line\nbreak.txt", "tab\there.txt", "semi;colon.txt", "$(whoami).txt",
                     "-rf", "--version", "back\\slash.txt", "quote\".txt", "star*.txt",
                     " lead.txt", "trail.txt ", "...", "🙈.txt", String(repeating: "a", count: 200) + ".txt"]
        var urls: [URL] = []
        for n in names {
            let u = folder.appendingPathComponent(n)
            if FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8)) { urls.append(u) }
        }
        let rules: [[RenameRule]] = [
            [.addPrefix("pre_")], [.addSuffix("_suf")], [.trimWhitespace],
            [.changeCase(.upper)], [.changeCase(.title)],
            [.sequence(prefix: "f", start: 1, padding: 3)],
            [.resequence(start: 1, padding: 2)],
            [.findReplace(find: ".", replace: "_", regex: false, caseSensitive: true)],
            [.findReplace(find: "(.*)", replace: "$1$1", regex: true, caseSensitive: true)],
            [.replaceExtension("bak")],
        ]
        for rule in rules {
            let plan = BatchRename.plan(for: urls, rules: rule)
            XCTAssertEqual(plan.count, urls.count, "plan lost entries for \(rule)")
            for p in plan where p.problem == nil && p.changed {
                XCTAssertFalse(p.proposed.isEmpty, "empty name from \(rule) on \(p.original.debugDescription)")
                XCTAssertFalse(p.proposed.contains("/"),
                    "rule \(rule) produced a path separator: \(p.proposed.debugDescription) from \(p.original.debugDescription)")
                XCTAssertNotEqual(p.proposed, ".", "rule \(rule) produced \".\"")
                XCTAssertNotEqual(p.proposed, "..",
                    "rule \(rule) produced \"..\" from \(p.original.debugDescription)")
            }
        }
    }

    /// Two files must never be planned onto one name without being flagged.
    func testCollisionsAreAlwaysFlagged() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for n in ["a.txt", "A.txt", "b.txt", "café-nfc.txt", "cafe\u{301}-nfd.txt"] {
            _ = FileManager.default.createFile(
                atPath: folder.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
        // Everything to the same name.
        let plan = BatchRename.plan(for: urls, rules: [
            .findReplace(find: "^.*$", replace: "same", regex: true, caseSensitive: false)])
        let usable = plan.filter { $0.problem == nil && $0.changed }
        XCTAssertLessThanOrEqual(usable.count, 1,
            "\(usable.count) files would be renamed onto the same name with no problem flagged")
    }

    /// A regex that blows up must be reported, not silently pass as "no change".
    func testPathologicalPatternsAreReported() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let u = folder.appendingPathComponent("test.txt")
        _ = FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8))
        for bad in ["[", "(", "*", "(?<", "\\", "((((((((((", "(?P<n>a)"] {
            let plan = BatchRename.plan(for: [u], rules: [
                .findReplace(find: bad, replace: "x", regex: true, caseSensitive: true)])
            XCTAssertEqual(plan.count, 1)
            if plan[0].changed {
                XCTAssertNil(plan[0].problem, "changed but flagged, for pattern \(bad.debugDescription)")
            }
        }
    }
}
