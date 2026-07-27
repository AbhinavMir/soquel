import XCTest
@testable import SoquelCore

final class ThemeLibraryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: ThemeLibrary.directoryURL)
        Settings.removeObject(forKey: "themeName")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: ThemeLibrary.directoryURL)
        Settings.removeObject(forKey: "themeName")
        Theme.apply(.empty)
        super.tearDown()
    }

    private func sample(_ name: String = "Test") -> Theme_File {
        Theme_File(
            name: name, author: "Somebody", about: "For testing.",
            light: ["accent": "#112233"], dark: ["accent": "#aabbcc"]
        )
    }

    func testTestsDoNotWriteToTheRealThemesFolder() {
        XCTAssertFalse(ThemeLibrary.directoryURL.path.hasSuffix("Application Support/Soquel/Themes"))
    }

    func testAThemeSurvivesSavingAndReading() throws {
        try ThemeLibrary.save(sample())
        let read = try XCTUnwrap(ThemeLibrary.named("Test"))
        XCTAssertEqual(read.author, "Somebody")
        XCTAssertEqual(read.light["accent"], "#112233")
        XCTAssertEqual(read.dark["accent"], "#aabbcc")
    }

    func testThemesAreListedInOrder() throws {
        for name in ["zebra", "Apple", "mango"] { try ThemeLibrary.save(sample(name)) }
        XCTAssertEqual(ThemeLibrary.all().map(\.name), ["Apple", "mango", "zebra"])
    }

    /// A theme named "../../bin/sh" must not write outside the themes folder.
    func testAThemeNameCannotEscapeTheFolder() {
        XCTAssertEqual(Theme_File(name: "../../bin/sh").safeFileName, "bin-sh.soquel-theme")
        XCTAssertEqual(Theme_File(name: "/etc/passwd").safeFileName, "etc-passwd.soquel-theme")
        XCTAssertFalse(Theme_File(name: "../../evil").safeFileName.contains(".."))
        XCTAssertFalse(Theme_File(name: "a/b/c").safeFileName.contains("/"))
    }

    func testAnUnnameableThemeStillGetsAFileName() {
        XCTAssertEqual(Theme_File(name: "").safeFileName, "theme.soquel-theme")
        XCTAssertEqual(Theme_File(name: "///").safeFileName, "theme.soquel-theme")
    }

    /// A file that will not parse is skipped rather than taking the list down.
    func testARubbishFileIsIgnored() throws {
        try ThemeLibrary.save(sample("Good"))
        try FileManager.default.createDirectory(
            at: ThemeLibrary.directoryURL, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(
            to: ThemeLibrary.directoryURL.appendingPathComponent("broken.soquel-theme"))
        XCTAssertEqual(ThemeLibrary.all().map(\.name), ["Good"])
    }

    func testUnrelatedFilesAreIgnored() throws {
        try ThemeLibrary.save(sample("Good"))
        try Data("x".utf8).write(to: ThemeLibrary.directoryURL.appendingPathComponent("notes.txt"))
        XCTAssertEqual(ThemeLibrary.all().count, 1)
    }

    // MARK: - Applying

    func testApplyingAThemeChangesTheColours() throws {
        try ThemeLibrary.apply(sample())
        XCTAssertEqual(Theme.config.dark["accent"], "#aabbcc")
        XCTAssertEqual(ThemeLibrary.currentName, "Test")
    }

    func testGoingBackToTheBuiltInColours() throws {
        try ThemeLibrary.apply(sample())
        ThemeLibrary.applyBuiltIn()
        XCTAssertTrue(Theme.config.dark.isEmpty)
        XCTAssertEqual(ThemeLibrary.currentName, "")
    }

    func testDeletingTheThemeInUseStopsUsingIt() throws {
        let theme = sample()
        try ThemeLibrary.save(theme)
        try ThemeLibrary.apply(theme)
        ThemeLibrary.delete(theme)
        XCTAssertEqual(ThemeLibrary.currentName, "")
        XCTAssertTrue(ThemeLibrary.all().isEmpty)
    }

    // MARK: - Capture and share

    func testCapturingTheCurrentColours() {
        Theme.apply(ThemeConfig(light: ["accent": "#ff0000"], dark: ["accent": "#00ff00"]))
        let captured = ThemeLibrary.capture(name: "Mine", author: "Me", about: "Notes")
        XCTAssertEqual(captured.name, "Mine")
        XCTAssertEqual(captured.light["accent"], "#ff0000")
        XCTAssertEqual(captured.dark["accent"], "#00ff00")
    }

    /// A theme pointing at a path on the author's disk works on one machine.
    /// The image has to travel inside the file.
    func testTheBackgroundImageTravelsInsideTheTheme() throws {
        let image = FileManager.default.temporaryDirectory
            .appendingPathComponent("soquel-bg-\(UUID().uuidString).png")
        try Data("pretend this is a png".utf8).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }

        Theme.apply(ThemeConfig(
            light: [:], dark: [:],
            background: BackgroundConfig(imagePath: image.path, opacity: 0.3,
                                         fit: .fill, includeSidebar: false)
        ))
        let captured = ThemeLibrary.capture(name: "Withbg", author: nil, about: nil)

        XCTAssertNotNil(captured.backgroundImage, "the image should be carried")
        XCTAssertNil(captured.background?.imagePath, "no path from the author's disk should remain")
        XCTAssertEqual(captured.background?.opacity, 0.3)

        // Applying it elsewhere writes the image back out and points at that.
        Theme.apply(.empty)
        try ThemeLibrary.apply(captured)
        let path = try XCTUnwrap(Theme.config.background?.imagePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasPrefix(ThemeLibrary.directoryURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)),
                       Data("pretend this is a png".utf8))
    }

    /// "Paper!", "Paper?" and "Paper" all collapse to the same filename. Saving
    /// one must not destroy another.
    func testAThemeWhoseNameCollidesDoesNotOverwriteTheOther() throws {
        try ThemeLibrary.save(Theme_File(name: "Paper", light: ["accent": "#111111"]))
        try ThemeLibrary.save(Theme_File(name: "Paper!", light: ["accent": "#222222"]))

        XCTAssertEqual(ThemeLibrary.all().count, 2, "one theme replaced the other")
        XCTAssertEqual(ThemeLibrary.named("Paper")?.light["accent"], "#111111")
        XCTAssertEqual(ThemeLibrary.named("Paper!")?.light["accent"], "#222222")
    }

    /// Saving the same theme again is editing it, not making a second copy.
    func testResavingAThemeOverwritesItsOwnFile() throws {
        try ThemeLibrary.save(Theme_File(name: "Paper", about: "first"))
        try ThemeLibrary.save(Theme_File(name: "Paper", about: "second"))
        XCTAssertEqual(ThemeLibrary.all().count, 1)
        XCTAssertEqual(ThemeLibrary.named("Paper")?.about, "second")
    }

    /// Deleting "Paper!" must not delete "Paper".
    func testDeletingACollidingThemeLeavesTheOtherAlone() throws {
        try ThemeLibrary.save(Theme_File(name: "Paper", light: ["accent": "#111111"]))
        let other = Theme_File(name: "Paper!", light: ["accent": "#222222"])
        try ThemeLibrary.save(other)

        ThemeLibrary.delete(other)
        XCTAssertEqual(ThemeLibrary.all().map(\.name), ["Paper"])
        XCTAssertEqual(ThemeLibrary.named("Paper")?.light["accent"], "#111111")
    }

    /// The two fields are independently optional, so a hand-authored theme can
    /// carry an image and no background block. The image must still be used.
    func testAThemeCarryingAnImageButNoBackgroundBlockStillShowsIt() throws {
        var theme = sample("Imaged")
        theme.background = nil
        theme.backgroundImage = Data("pretend this is a png".utf8).base64EncodedString()

        try ThemeLibrary.apply(theme)
        let path = try XCTUnwrap(Theme.config.background?.imagePath,
                                 "the image was written out and then the path dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// When the image cannot be read there is nothing to carry, and leaving the
    /// path behind ships the author's home directory to the recipient.
    func testAnUnreadableImageLeavesNoPathBehind() {
        Theme.apply(ThemeConfig(
            light: [:], dark: [:],
            background: BackgroundConfig(imagePath: "/nowhere/gone.png", opacity: 0.3,
                                         fit: .fill, includeSidebar: false)
        ))
        let captured = ThemeLibrary.capture(name: "Broken", author: nil, about: nil)
        XCTAssertNil(captured.backgroundImage)
        XCTAssertNil(captured.background?.imagePath, "the author's path was shipped")
        XCTAssertEqual(captured.background?.opacity, 0.3, "the rest of the settings survive")
    }

    func testInstallingAThemeFileSomebodySent() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sent.soquel-theme")
        try JSONEncoder().encode(sample("Sent")).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let installed = try ThemeLibrary.install(from: outside)
        XCTAssertEqual(installed.name, "Sent")
        XCTAssertEqual(ThemeLibrary.all().map(\.name), ["Sent"])
    }

    func testInstallingSomethingThatIsNotAThemeFails() throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).soquel-theme")
        try Data("nope".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try ThemeLibrary.install(from: junk))
    }

    // MARK: - What ships

    func testTheBundledThemesAreWrittenOnce() throws {
        ThemeLibrary.installBuiltInsIfMissing()
        let names = Set(ThemeLibrary.all().map(\.name))
        XCTAssertEqual(names, Set(ThemeLibrary.builtIn.map(\.name)))

        // An edit to a bundled theme must survive the next launch.
        var edited = try XCTUnwrap(ThemeLibrary.named("Paper"))
        edited.about = "I changed this"
        try ThemeLibrary.save(edited)
        ThemeLibrary.installBuiltInsIfMissing()
        XCTAssertEqual(ThemeLibrary.named("Paper")?.about, "I changed this")
    }

    func testEveryBundledThemeCoversEverySlotInBothAppearances() {
        for theme in ThemeLibrary.builtIn where !theme.light.isEmpty {
            for slot in ThemeConfig.Slot.allCases {
                XCTAssertNotNil(theme.light[slot.rawValue], "\(theme.name) light \(slot.rawValue)")
                XCTAssertNotNil(theme.dark[slot.rawValue], "\(theme.name) dark \(slot.rawValue)")
            }
        }
    }

    func testEveryBundledColourParses() {
        for theme in ThemeLibrary.builtIn {
            for hex in Array(theme.light.values) + Array(theme.dark.values) {
                XCTAssertNotNil(NSColor(hexString: hex), "\(theme.name): \(hex) does not parse")
            }
        }
    }

    func testChangeIsAnnounced() throws {
        expectation(forNotification: .soquelThemesChanged, object: nil)
        try ThemeLibrary.save(sample())
        waitForExpectations(timeout: 2)
    }
}
