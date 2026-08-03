import AppKit

/// Whether a volume has a Trash to move something into.
///
/// Dragging to the Trash on a network share deletes permanently, and people
/// find this out by losing something. A read-only volume refuses outright,
/// which is safe but is reported as a generic error nobody can act on.
enum TrashPolicy {
    enum Outcome: Equatable {
        /// The item goes to a Trash and can be put back.
        case recoverable
        /// The volume has no Trash. Deleting is permanent.
        case permanent(volume: String)
        /// Nothing can be deleted here at all.
        case readOnly(volume: String)

        var isRecoverable: Bool { self == .recoverable }
    }

    static func outcome(for url: URL) -> Outcome {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
            .volumeSupportsFileCloningKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .recoverable }
        let name = values.volumeName ?? values.volume?.lastPathComponent ?? "this volume"

        if values.volumeIsReadOnly == true { return .readOnly(volume: name) }
        // A remote volume may or may not have a working .Trashes — on a NAS the
        // shared one is usually owned by whoever deleted first. Treating remote
        // as permanent is the honest reading: it warns when it might be wrong
        // in the direction that does not lose a file.
        if values.volumeIsLocal == false { return .permanent(volume: name) }
        return .recoverable
    }

    /// What to say before deleting. nil when the ordinary Trash applies and
    /// there is nothing worth interrupting for.
    static func warning(for urls: [URL]) -> (title: String, body: String)? {
        let outcomes = urls.map(outcome(for:))

        if let first = outcomes.first(where: { if case .readOnly = $0 { return true }; return false }),
           case .readOnly(let volume) = first {
            return ("\(volume) is read-only",
                    "Nothing on it can be deleted or moved to the Trash.")
        }

        let permanent = outcomes.compactMap { outcome -> String? in
            if case .permanent(let volume) = outcome { return volume }
            return nil
        }
        guard let volume = permanent.first else { return nil }

        let count = permanent.count
        let what = count == 1 ? "This item is" : "\(count) of these items are"
        return ("Deleting from \(volume) cannot be undone",
                "\(what) on a network volume, which has no Trash. They will be deleted "
                + "outright rather than moved somewhere you can get them back from.")
    }

    /// Whether every item can be trashed normally, so the ordinary path can
    /// skip asking.
    static func allRecoverable(_ urls: [URL]) -> Bool {
        urls.allSatisfy { outcome(for: $0).isRecoverable }
    }
}
