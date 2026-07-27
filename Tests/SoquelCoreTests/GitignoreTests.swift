import XCTest
@testable import SoquelCore

final class IgnoreRuleTests: XCTestCase {
    private func rule(_ line: String) -> IgnoreRule? { IgnoreRule(line: line) }

    private func matches(_ pattern: String, _ path: String, isDirectory: Bool = false) -> Bool {
        rule(pattern)?.matches(relativePath: path, isDirectory: isDirectory) ?? false
    }

    // MARK: - Parsing

    func testBlankLinesAndCommentsAreNotRules() {
        XCTAssertNil(rule(""))
        XCTAssertNil(rule("   "))
        XCTAssertNil(rule("# a comment"))
    }

    func testAnEscapedHashIsALiteralName() {
        XCTAssertTrue(matches("\\#notacomment", "#notacomment"))
    }

    func testNegationIsRecognised() {
        XCTAssertEqual(rule("!keep.txt")?.isNegated, true)
        XCTAssertEqual(rule("drop.txt")?.isNegated, false)
    }

    func testTrailingSlashMeansDirectoriesOnly() {
        XCTAssertEqual(rule("build/")?.directoriesOnly, true)
        XCTAssertTrue(matches("build/", "build", isDirectory: true))
        XCTAssertFalse(matches("build/", "build", isDirectory: false))
    }

    // MARK: - Matching

    func testABareNameMatchesAtAnyDepth() {
        XCTAssertTrue(matches("node_modules", "node_modules", isDirectory: true))
        XCTAssertTrue(matches("node_modules", "packages/web/node_modules", isDirectory: true))
        XCTAssertTrue(matches("*.log", "deep/nested/thing.log"))
    }

    /// A slash in the middle anchors the pattern to the ignore file's directory.
    func testAPatternWithASlashIsAnchored() {
        XCTAssertTrue(matches("src/generated", "src/generated", isDirectory: true))
        XCTAssertFalse(matches("src/generated", "vendor/src/generated", isDirectory: true))
    }

    func testALeadingSlashAnchorsToTheRoot() {
        XCTAssertTrue(matches("/TODO.md", "TODO.md"))
        XCTAssertFalse(matches("/TODO.md", "docs/TODO.md"))
    }

    func testStarDoesNotCrossASlash() {
        XCTAssertTrue(matches("*.swift", "File.swift"))
        XCTAssertFalse(matches("src/*.swift", "src/deep/File.swift"))
    }

    func testDoubleStarCrossesDirectories() {
        XCTAssertTrue(matches("src/**/generated", "src/a/b/generated", isDirectory: true))
        XCTAssertTrue(matches("src/**/generated", "src/generated", isDirectory: true))
        XCTAssertTrue(matches("logs/**", "logs/a/b.txt"))
    }

    func testLeadingDoubleStarMatchesAnyLeadingPath() {
        XCTAssertTrue(matches("**/build", "a/b/build", isDirectory: true))
        XCTAssertTrue(matches("**/build", "build", isDirectory: true))
    }

    func testQuestionMarkIsOneCharacter() {
        XCTAssertTrue(matches("file?.txt", "file1.txt"))
        XCTAssertFalse(matches("file?.txt", "file12.txt"))
        XCTAssertFalse(matches("file?.txt", "file.txt"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(matches("file[0-9].txt", "file7.txt"))
        XCTAssertFalse(matches("file[0-9].txt", "filex.txt"))
        XCTAssertTrue(matches("file[!0-9].txt", "filex.txt"))
    }

    /// A dot in a pattern is a dot, not "any character".
    func testDotsAreLiteral() {
        XCTAssertTrue(matches(".env", ".env"))
        XCTAssertFalse(matches(".env", "xenv"))
    }

    func testPlusAndParenthesesAreLiteral() {
        XCTAssertTrue(matches("a+b.txt", "a+b.txt"))
        XCTAssertFalse(matches("a+b.txt", "aab.txt"))
        XCTAssertTrue(matches("thing(1).txt", "thing(1).txt"))
    }
}

final class IgnoreStackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeIgnore(_ contents: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
    }

    private func stack(_ contents: String) -> IgnoreStack {
        let stack = IgnoreStack()
        stack.push(rules: IgnoreStack.parse(contents), for: root)
        return stack
    }

    func testTheGitDirectoryIsAlwaysIgnored() {
        let empty = IgnoreStack()
        XCTAssertTrue(empty.ignores(root.appendingPathComponent(".git"), isDirectory: true))
    }

    func testAnEmptyStackIgnoresNothingElse() {
        let empty = IgnoreStack()
        XCTAssertFalse(empty.ignores(root.appendingPathComponent("anything.txt"), isDirectory: false))
    }

    func testSimpleExclusion() {
        let ignore = stack("*.log\nbuild/\n")
        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("run.log"), isDirectory: false))
        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("build"), isDirectory: true))
        XCTAssertFalse(ignore.ignores(root.appendingPathComponent("build.swift"), isDirectory: false))
    }

    /// The last matching rule wins, which is what makes `!` work at all.
    func testNegationReIncludes() {
        let ignore = stack("*.log\n!keep.log\n")
        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("run.log"), isDirectory: false))
        XCTAssertFalse(ignore.ignores(root.appendingPathComponent("keep.log"), isDirectory: false))
    }

    func testOrderMattersForNegation() {
        // Re-including first and excluding after leaves it excluded.
        let ignore = stack("!keep.log\n*.log\n")
        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("keep.log"), isDirectory: false))
    }

    func testNestedIgnoreFileOverridesItsParent() throws {
        let nested = root.appendingPathComponent("web")
        try writeIgnore("*.log\n", in: root)
        try writeIgnore("!important.log\n", in: nested)

        let ignore = IgnoreStack()
        ignore.pushIgnoreFile(in: root)
        ignore.pushIgnoreFile(in: nested)

        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("a.log"), isDirectory: false))
        XCTAssertTrue(ignore.ignores(nested.appendingPathComponent("other.log"), isDirectory: false))
        XCTAssertFalse(ignore.ignores(nested.appendingPathComponent("important.log"), isDirectory: false))
    }

    func testARuleOnlyAppliesBelowItsOwnDirectory() throws {
        let nested = root.appendingPathComponent("web")
        try writeIgnore("secret.txt\n", in: nested)

        let ignore = IgnoreStack()
        ignore.pushIgnoreFile(in: nested)
        XCTAssertTrue(ignore.ignores(nested.appendingPathComponent("secret.txt"), isDirectory: false))
        XCTAssertFalse(ignore.ignores(root.appendingPathComponent("secret.txt"), isDirectory: false))
    }

    func testMissingIgnoreFileIsNotAnError() {
        let ignore = IgnoreStack()
        XCTAssertFalse(ignore.pushIgnoreFile(in: root))
        XCTAssertTrue(ignore.isEmpty)
    }

    /// Starting a search deep inside a repository must still honour the rules
    /// written at the top of it.
    func testRulesAreCollectedUpToTheRepositoryRoot() throws {
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try writeIgnore("*.tmp\n", in: root)

        let ignore = IgnoreStack.forTree(startingAt: deep)
        XCTAssertTrue(ignore.ignores(deep.appendingPathComponent("scratch.tmp"), isDirectory: false))
    }

    func testTheWalkStopsAtTheRepositoryRoot() throws {
        // A .gitignore above the repository root belongs to a different
        // repository and must not be applied.
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try writeIgnore("outside.txt\n", in: root)

        let ignore = IgnoreStack.forTree(startingAt: repo)
        XCTAssertFalse(ignore.ignores(repo.appendingPathComponent("outside.txt"), isDirectory: false))
    }

    func testCommentsAndBlankLinesAreSkipped() {
        let ignore = stack("# build output\n\n  \nbuild/\n")
        XCTAssertTrue(ignore.ignores(root.appendingPathComponent("build"), isDirectory: true))
        XCTAssertFalse(ignore.ignores(root.appendingPathComponent("# build output"), isDirectory: false))
    }
}

/// Checks the engine against what `git check-ignore` actually says, so the
/// semantics are not merely self-consistent.
final class GitignoreAgainstGitTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/git"), "git not present")
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run("/usr/bin/git", ["init", "-q", repo.path])
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = repo
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `git check-ignore` exits 0 when the path is ignored.
    private func gitIgnores(_ relativePath: String) throws -> Bool {
        try run("/usr/bin/git", ["check-ignore", "-q", relativePath]) == 0
    }

    func testMatchesGitOnACommonIgnoreFile() throws {
        let contents = """
        # build output
        build/
        *.log
        !keep.log
        node_modules
        /root-only.txt
        src/*.generated.swift
        **/cache
        .env
        """
        try contents.write(
            to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )

        let cases: [(String, Bool)] = [
            ("build", true),
            ("run.log", false),          // directory-only rule; as a file it is *.log
            ("keep.log", false),
            ("node_modules", true),
            ("root-only.txt", true),
            ("docs/root-only.txt", false),
            ("src/Thing.generated.swift", true),
            ("src/deep/Thing.generated.swift", false),
            ("a/b/cache", true),
            (".env", true),
            ("README.md", false),
        ]

        let stack = IgnoreStack()
        stack.pushIgnoreFile(in: repo)

        for (path, _) in cases {
            let isDirectory = !path.contains(".")
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: isDirectory ? url : url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !isDirectory { try Data().write(to: url) }

            let expected = try gitIgnores(path + (isDirectory ? "/" : ""))
            let actual = stack.ignores(url, isDirectory: isDirectory)
            XCTAssertEqual(actual, expected, "disagreed with git about “\(path)”")
        }
    }
}
