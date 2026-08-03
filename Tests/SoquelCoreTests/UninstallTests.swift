import XCTest
@testable import SoquelCore

final class UninstallTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soquel-uninstall-\(UUID().uuidString)", isDirectory: true)
        for (root, _) in Uninstall.searchRoots(home: home) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    /// com.acme.Thing must not drag in com.acme.ThingElse.
    func testTheIdentifierMatchIsNotASubstringMatch() {
        XCTAssertEqual(Uninstall.matches("com.acme.Thing.plist", identifier: "com.acme.Thing", name: "Thing"), .exact)
        XCTAssertNil(Uninstall.matches("com.acme.ThingElse.plist", identifier: "com.acme.Thing", name: "Other"))
    }

    /// A Caches folder is named `com.acme.Thing` with no extension. Treating
    /// ".Thing" as one and stripping it missed the commonest case there is.
    func testAFolderNamedLikeAnIdentifierMatches() {
        XCTAssertEqual(
            Uninstall.matches("com.acme.Thing", identifier: "com.acme.Thing", name: "Thing"),
            .exact
        )
    }

    /// "Mail" must not claim "MailChimp Designer".
    func testTheNameMatchNeedsAWordBoundary() {
        XCTAssertEqual(Uninstall.matches("Mail", identifier: nil, name: "Mail"), .byName)
        XCTAssertEqual(Uninstall.matches("Mail Downloads", identifier: nil, name: "Mail"), .byName)
        XCTAssertNil(Uninstall.matches("MailChimp Designer", identifier: nil, name: "Mail"))
    }

    /// An identifier match beats a name match on the same file, because it is
    /// the one that can be trusted.
    func testAnIdentifierMatchOutranksAName() {
        XCTAssertEqual(
            Uninstall.matches("com.acme.Thing", identifier: "com.acme.Thing", name: "com.acme.Thing"),
            .exact
        )
        XCTAssertTrue(Uninstall.Confidence.exact < Uninstall.Confidence.byName)
    }

    func testLeftoversAreFoundAcrossTheUsualDirectories() throws {
        let caches = home.appendingPathComponent("Library/Caches/com.acme.Thing", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: caches.appendingPathComponent("blob"))

        let prefs = home.appendingPathComponent("Library/Preferences/com.acme.Thing.plist")
        try Data("x".utf8).write(to: prefs)

        // A bundle identifier cannot be faked without a real .app, so match on
        // the name and check the directories are searched at all.
        let found = Uninstall.leftovers(
            for: URL(fileURLWithPath: "/Applications/com.acme.Thing.app"), home: home
        )
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.kind)), ["Cache", "Preferences"])
    }

    /// Something belonging to another application is left alone.
    func testAnUnrelatedFolderIsNotReported() throws {
        let other = home.appendingPathComponent("Library/Application Support/Something Else", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let found = Uninstall.leftovers(for: URL(fileURLWithPath: "/Applications/Thing.app"), home: home)
        XCTAssertTrue(found.isEmpty)
    }

    func testTheSummaryReportsNothingWhenThereIsNothing() {
        XCTAssertEqual(Uninstall.summary([]), "Nothing left behind")
    }

    func testTheDisplayNameDropsTheExtension() {
        XCTAssertEqual(Uninstall.displayName(of: URL(fileURLWithPath: "/Applications/Xcode.app")), "Xcode")
    }
}
