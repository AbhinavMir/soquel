import AppKit

/// User-editable colours, stored as a readable JSON file so advanced users can
/// version it or share it. Anything absent or malformed falls back to the
/// built-in value rather than to an arbitrary substitute.
struct ThemeConfig: Codable, Equatable {
    /// Every customisable colour. Raw values are the JSON keys.
    enum Slot: String, CaseIterable, Codable {
        case accent
        case selectionFill
        case selectionFillInactive
        case rowAlternate
        case chrome
        case hairline
        case danger
    }

    var light: [String: String]
    var dark: [String: String]
    /// Optional background image behind the file list.
    var background: BackgroundConfig?

    static let empty = ThemeConfig(light: [:], dark: [:], background: nil)

    /// Decoding tolerates a file written before backgrounds existed.
    init(light: [String: String], dark: [String: String], background: BackgroundConfig? = nil) {
        self.light = light
        self.dark = dark
        self.background = background
    }

    /// The colour for a slot, or nil when the user has not set one (or set one
    /// that could not be parsed).
    func color(for slot: Slot, dark isDark: Bool) -> NSColor? {
        let table = isDark ? dark : light
        guard let hex = table[slot.rawValue] else { return nil }
        return NSColor(hexString: hex)
    }

    // MARK: - Storage

    /// `~/Library/Application Support/Soquel/`.
    ///
    /// Tests get their own directory. The suite applies and resets themes
    /// freely, and must not rewrite the colours of whoever is running it.
    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOQUEL_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("soquel-test-support-\(getpid())", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Soquel", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("theme.json") }

    /// Reads the file. A missing file is normal and yields no overrides; a
    /// malformed file also yields no overrides, and the caller reports why.
    static func load() throws -> ThemeConfig {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return .empty }
        return try JSONDecoder().decode(ThemeConfig.self, from: data)
    }

    /// Writes a fully populated file showing every slot at its current value,
    /// so the format is discoverable by opening it.
    ///
    /// `background` is carried through rather than defaulted: this runs when
    /// the user asks to *look* at the file, and a look must not discard the
    /// image they chose.
    @discardableResult
    static func writeTemplate(
        background: BackgroundConfig?,
        from resolved: (Slot, Bool) -> NSColor
    ) throws -> URL {
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        for slot in Slot.allCases {
            light[slot.rawValue] = resolved(slot, false).hexString
            dark[slot.rawValue] = resolved(slot, true).hexString
        }
        let config = ThemeConfig(light: light, dark: dark,
                                 background: background ?? BackgroundConfig.none)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func write(_ config: ThemeConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }

    static func removeFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

extension NSColor {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`, with or without the leading
    /// hash. Returns nil for anything else — a wrong-but-present colour is
    /// worse than falling back to the designed default.
    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }

        let expanded: String
        switch text.count {
        case 3: expanded = text.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = text
        default: return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour is translucent.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
