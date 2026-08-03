import AppKit

/// Finder tags, read and written through the same extended attribute Finder
/// uses, so a tag set here shows up there and the other way round.
enum Tags {
    /// The seven Finder ships, plus any name the user has invented. Finder's
    /// colour field is three bits, which is where the limit comes from; a name
    /// with no colour is still a tag and is drawn in grey.
    static let standard: [(name: String, colour: NSColor)] = [
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Blue", .systemBlue),
        ("Purple", .systemPurple),
        ("Grey", .systemGray),
    ]

    static func colour(named name: String) -> NSColor? {
        standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.colour
    }

    static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Written through NSURL: the Swift `URLResourceValues.tagNames` setter is
    /// macOS 26 and up, and this ships to 13.
    @discardableResult
    static func write(_ names: [String], to url: URL) -> Error? {
        do {
            try (url as NSURL).setResourceValue(
                names.isEmpty ? nil : names as NSArray, forKey: .tagNamesKey
            )
            return nil
        } catch {
            return error
        }
    }

    static func toggle(_ name: String, on url: URL) -> Error? {
        var names = read(url)
        if let index = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.remove(at: index)
        } else {
            names.append(name)
        }
        return write(names, to: url)
    }

    /// The colour a whole row is tinted. The first tag with a colour wins; a
    /// file tagged Red and Blue is drawn red rather than some blend of the two
    /// that matches neither.
    static func rowTint(for names: [String]) -> NSColor? {
        for name in names {
            if let colour = colour(named: name) { return colour }
        }
        return names.isEmpty ? nil : NSColor.systemGray
    }

    // MARK: - Volumes that cannot keep them

    /// Whether a volume can store tags at all.
    ///
    /// Tags live in an extended attribute. exFAT and FAT have none, so a tag
    /// written to a file there is silently dropped — the write appears to work
    /// and the tag is gone next time the disk is mounted. This is the cause of
    /// the standing "tags not working on my external drive" complaint.
    static func volumeSupportsTags(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeSupportsExtendedSecurityKey, .volumeURLKey,
        ]) else { return true }
        guard let volume = values.volume else { return true }
        return !formatDropsTags(nameOfFormat(at: volume))
    }

    /// The filesystem's own name, e.g. "APFS", "exFAT", "SMB".
    static func nameOfFormat(at volume: URL) -> String? {
        var stats = statfs()
        guard statfs(volume.path, &stats) == 0 else { return nil }
        return withUnsafeBytes(of: stats.f_fstypename) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }

    /// Formats with no extended attributes to put a tag in.
    static func formatDropsTags(_ format: String?) -> Bool {
        guard let format = format?.lowercased() else { return false }
        return ["exfat", "msdos", "fat", "fat32", "vfat", "ntfs"].contains(format)
    }

    /// What to say before writing a tag somewhere it will not survive. nil when
    /// there is nothing to warn about.
    static func warning(for url: URL) -> String? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        let format = nameOfFormat(at: volume)
        guard formatDropsTags(format) else { return nil }
        let name = format?.uppercased() ?? "this disk"
        return "\(name) has nowhere to store a tag. It will look like it worked and be gone "
            + "when the disk is next mounted."
    }
}
