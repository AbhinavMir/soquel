import Foundation

/// Which releases this copy follows, and what a version number means.
///
/// The three numbers are not decoration. Each one says who a release is for:
///
///     2.0.0   a big release — the shape of the application changed
///     1.2.0   a sequential release — finished work, for everybody
///     1.1.2   a nightly — the day's work, for people who want it early
///
/// So the middle number moves for stable releases and the last one moves for
/// nightlies. Somebody on stable sees 1.1.0, 1.2.0, 1.3.0 and never a nightly.
/// Somebody on nightly sees every one of those and 1.2.1, 1.2.2 in between.
enum UpdateChannel: String, CaseIterable {
    /// Sequential releases only. The last number is always 0.
    case stable
    /// Everything, including the day's builds.
    case nightly

    var title: String {
        switch self {
        case .stable: return "Sequential releases"
        case .nightly: return "Nightly builds"
        }
    }

    var detail: String {
        switch self {
        case .stable:
            return "Finished work only — 1.2.0, 1.3.0, and big releases like 2.0.0. "
                + "Each one has been through the whole test suite and notarised."
        case .nightly:
            return "The day's work as it lands — 1.2.1, 1.2.2, and every sequential "
                + "release as well. Newer, and less proven. A nightly is where a defect "
                + "gets found, which is the point of running one."
        }
    }

    static var current: UpdateChannel {
        get {
            (Settings.object(forKey: "updateChannel") as? String)
                .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        }
        set { Settings.set(newValue.rawValue, forKey: "updateChannel") }
    }
}

/// Three numbers, compared as numbers rather than as text.
///
/// "1.10.0" is newer than "1.9.0"; comparing the strings says the opposite,
/// which is the oldest bug in version handling.
struct Version: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads "v1.2.3", "1.2.3", "1.2", or "1". Anything else is not a version,
    /// and gives nil rather than a guess — a tag nobody can read is not a
    /// reason to tell somebody to upgrade.
    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // "1.2.3-beta1" stops at the dash rather than failing outright.
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// A release with a patch number is a nightly. `1.2.0` is sequential;
    /// `1.2.1` is the work that happened after it.
    var isNightly: Bool { patch != 0 }

    /// Whether somebody on this channel should be offered this version.
    func suits(_ channel: UpdateChannel) -> Bool {
        switch channel {
        case .stable: return !isNightly
        case .nightly: return true
        }
    }

    static func < (a: Version, b: Version) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
