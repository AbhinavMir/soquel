import AppKit

extension Notification.Name {
    static let soquelThemesChanged = Notification.Name("app.soquel.themesChanged")
}

/// Themes as files you can keep, swap between, and send to someone.
///
/// Before this a theme was seven hex values typed into `theme.json`, with no
/// way to have two of them or to give one away. A theme is now a document in
/// `~/Library/Application Support/Soquel/Themes/`, and switching is picking a
/// name.
///
/// A theme carries its background image rather than pointing at one. A file
/// naming `/Users/someone/Pictures/blue.jpg` works on exactly one machine,
/// which makes it a note describing a theme rather than a theme.
struct Theme_File: Codable, Equatable {
    var name: String
    var author: String?
    /// Free text shown under the name in the picker.
    var about: String?
    var light: [String: String]
    var dark: [String: String]
    /// How the background is drawn, if there is one.
    var background: BackgroundConfig?
    /// The background image itself, base64, so the theme is one file.
    var backgroundImage: String?

    static let fileExtension = "soquel-theme"

    init(name: String, author: String? = nil, about: String? = nil,
         light: [String: String] = [:], dark: [String: String] = [:],
         background: BackgroundConfig? = nil, backgroundImage: String? = nil) {
        self.name = name
        self.author = author
        self.about = about
        self.light = light
        self.dark = dark
        self.background = background
        self.backgroundImage = backgroundImage
    }

    /// A filename that cannot escape the themes folder however the theme is
    /// named. A theme called "../../bin/sh" writes to "bin-sh".
    var safeFileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        let collapsed = cleaned
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            // "../../bin/sh" collapses to "-bin-sh"; the leading dash is a
            // leftover from the path it was trying to be, not part of a name.
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return (collapsed.isEmpty ? "theme" : collapsed) + "." + Self.fileExtension
    }
}

/// The themes on this machine.
enum ThemeLibrary {
    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOQUEL_THEMES_DIR"] {
            return URL(fileURLWithPath: override)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-test-themes-\(getpid())")
        }
        return ThemeConfig.directoryURL.appendingPathComponent("Themes", isDirectory: true)
    }

    /// The theme in force, by name. Empty means the built-in colours.
    static var currentName: String {
        get { Settings.string(forKey: "themeName") ?? "" }
        set { Settings.set(newValue, forKey: "themeName") }
    }

    // MARK: - Reading

    /// Every theme on disk, by name. A file that will not parse is skipped
    /// rather than taking the list down with it.
    static func all() -> [Theme_File] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == Theme_File.fileExtension }
            .compactMap { read($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func read(_ url: URL) -> Theme_File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Theme_File.self, from: data)
    }

    static func named(_ name: String) -> Theme_File? {
        all().first { $0.name == name }
    }

    // MARK: - Writing

    /// Where a theme is written.
    ///
    /// `safeFileName` maps every awkward character to a dash, so "Paper!",
    /// "Paper?" and "Paper" all collapse to Paper.soquel-theme. Saving one must
    /// not destroy another, so a name that lands on a file belonging to a
    /// *differently* named theme gets a numbered suffix instead. Re-saving a
    /// theme under its own name still overwrites, which is what editing means.
    static func fileURL(for theme: Theme_File) -> URL {
        /// Free to take: nothing there, or what is there is this same theme.
        func isOurs(_ url: URL) -> Bool {
            guard let existing = read(url) else { return true }
            return existing.name == theme.name
        }

        let plain = directoryURL.appendingPathComponent(theme.safeFileName)
        if isOurs(plain) { return plain }

        let stem = theme.safeFileName.replacingOccurrences(
            of: "." + Theme_File.fileExtension, with: "")
        for suffix in 2...999 {
            let candidate = directoryURL
                .appendingPathComponent("\(stem)-\(suffix).\(Theme_File.fileExtension)")
            if isOurs(candidate) { return candidate }
        }
        return plain
    }

    @discardableResult
    static func save(_ theme: Theme_File) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: theme)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(theme).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .soquelThemesChanged, object: nil)
        return url
    }

    static func delete(_ theme: Theme_File) {
        // Via fileURL(for:) so removing "Paper!" cannot delete "Paper".
        let url = fileURL(for: theme)
        try? FileManager.default.removeItem(at: url)
        if currentName == theme.name { currentName = "" }
        NotificationCenter.default.post(name: .soquelThemesChanged, object: nil)
    }

    /// Copies a theme file someone sent into the library.
    @discardableResult
    static func install(from url: URL) throws -> Theme_File {
        guard let theme = read(url) else {
            throw NSError(domain: "app.soquel.theme", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "That file is not a Soquel theme.",
            ])
        }
        try save(theme)
        return theme
    }

    // MARK: - Applying

    /// Makes a theme current: its colours and background become the live ones.
    ///
    /// The background image is written out beside the theme, because the rest
    /// of the application draws backgrounds from a path on disk and there is no
    /// reason to teach it a second way.
    static func apply(_ theme: Theme_File) throws {
        var background = theme.background

        if let encoded = theme.backgroundImage, let data = Data(base64Encoded: encoded) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let imageURL = fileURL(for: theme)
                .deletingPathExtension()
                .appendingPathExtension("png")
            try data.write(to: imageURL, options: .atomic)
            // A theme may carry an image without carrying a background block —
            // the two fields are independently optional. Assigning through a nil
            // optional is a no-op, which would write the png out and then drop
            // the path, so supply the defaults and set the path on those.
            //
            // Spelt out rather than `?? .none`: in an optional context Swift
            // reads a bare `.none` as Optional.none, which is nil, which is the
            // bug this line exists to fix.
            var resolved = background ?? BackgroundConfig.none
            resolved.imagePath = imageURL.path
            background = resolved
        }

        Theme.apply(ThemeConfig(light: theme.light, dark: theme.dark, background: background))
        currentName = theme.name
        Log.info(.ui, "Theme “\(theme.name)” applied")
    }

    /// Back to the colours the application ships with.
    static func applyBuiltIn() {
        Theme.apply(.empty)
        currentName = ""
    }

    /// Captures whatever is in force now as a theme, so a set of colours
    /// arrived at by fiddling can be kept and handed on.
    static func capture(name: String, author: String?, about: String?) -> Theme_File {
        let config = Theme.config
        var theme = Theme_File(
            name: name, author: author, about: about,
            light: config.light, dark: config.dark, background: config.background
        )
        // The image travels with the theme rather than being referred to. The
        // path is cleared either way: when the file cannot be read there is no
        // image to carry, and leaving the path behind would ship the author's
        // home directory layout to whoever they send the theme to, pointing at
        // a file that machine does not have.
        if config.background?.imagePath != nil {
            if let url = config.background?.imageURL, let data = try? Data(contentsOf: url) {
                theme.backgroundImage = data.base64EncodedString()
            }
            theme.background?.imagePath = nil
        }
        return theme
    }

    // MARK: - What ships with it

    /// Themes written out on first run, so the picker is not empty and so
    /// there is a worked example to copy.
    static let builtIn: [Theme_File] = [
        Theme_File(
            name: "Soquel",
            author: "Soquel",
            about: "The colours the application ships with.",
            light: [:], dark: [:]
        ),
        Theme_File(
            name: "Paper",
            author: "Soquel",
            about: "Warm and low contrast, for reading rather than scanning.",
            light: [
                "accent": "#8a5a2b", "selectionFill": "#8a5a2b", "selectionFillInactive": "#e0d7c8",
                "rowAlternate": "#f7f2e8", "chrome": "#faf6ee", "hairline": "#e2d8c6",
                "danger": "#a33b2a",
            ],
            dark: [
                "accent": "#d8a76a", "selectionFill": "#8a5a2b", "selectionFillInactive": "#3a332a",
                "rowAlternate": "#22201c", "chrome": "#1b1916", "hairline": "#332e26",
                "danger": "#d4705c",
            ]
        ),
        Theme_File(
            name: "Slate",
            author: "Soquel",
            about: "Grey and blue, closer to the system's own.",
            light: [
                "accent": "#2f6fc4", "selectionFill": "#2f6fc4", "selectionFillInactive": "#d6dce3",
                "rowAlternate": "#f4f6f8", "chrome": "#fbfcfd", "hairline": "#dde4ea",
                "danger": "#c0392b",
            ],
            dark: [
                "accent": "#6ea3e8", "selectionFill": "#2f6fc4", "selectionFillInactive": "#2a323b",
                "rowAlternate": "#171b20", "chrome": "#12161a", "hairline": "#232a32",
                "danger": "#e06c5c",
            ]
        ),
        Theme_File(
            name: "Terminal",
            author: "Soquel",
            about: "Green on near-black, for people who never left.",
            light: [
                "accent": "#1f7a3d", "selectionFill": "#1f7a3d", "selectionFillInactive": "#d5e6d9",
                "rowAlternate": "#f2f7f3", "chrome": "#ffffff", "hairline": "#d9e3db",
                "danger": "#b03030",
            ],
            dark: [
                "accent": "#3ddc7f", "selectionFill": "#1f7a3d", "selectionFillInactive": "#1e2a22",
                "rowAlternate": "#0f1512", "chrome": "#0a0f0c", "hairline": "#1c2a20",
                "danger": "#ff6b5b",
            ]
        ),
    ]

    /// Writes the built-in themes if they are not there. Existing files are
    /// left alone: someone may have edited one, and overwriting an edit to
    /// restore a default nobody asked for is the rudest thing this could do.
    static func installBuiltInsIfMissing() {
        for theme in builtIn {
            let url = directoryURL.appendingPathComponent(theme.safeFileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? save(theme)
        }
    }
}
