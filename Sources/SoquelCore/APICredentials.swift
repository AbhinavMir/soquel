import Foundation

/// The keys for Clean This Folder, one per provider.
///
/// A file, not the Keychain. The Keychain ties an item's access control to the
/// exact binary that wrote it, and every update is a different binary, so every
/// update asked the user for their login password to reach a key they had
/// already given. A password prompt on each update is worse than the thing it
/// was protecting against.
///
/// So: `credentials.json`, mode 0600, beside the other files but deliberately
/// not inside `settings.json` — that one is documented as editable by hand,
/// opened from the View menu, and is what somebody pastes into a bug report.
/// This one is never opened by the application and never printed.
enum APICredentials {
    static var directory: URL {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true)[0])
            .appendingPathComponent("Soquel")
    }

    static var file: URL { directory.appendingPathComponent("credentials.json") }

    private static let lock = NSLock()

    private static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return keys
    }

    private static func write(_ keys: [String: String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: keys, options: [.sortedKeys])
        else { return }
        // Created 0600 rather than written and then chmod'd: between those two
        // steps the key would be readable by anybody on the machine.
        FileManager.default.createFile(
            atPath: file.path, contents: data,
            attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Whether a key is stored, without reading it.
    static func isSet(for provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return read()[provider]?.isEmpty == false
    }

    static func key(for provider: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = read()[provider]
        return (value?.isEmpty ?? true) ? nil : value
    }

    @discardableResult
    static func store(_ key: String, for provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = read()
        if trimmed.isEmpty { keys.removeValue(forKey: provider) } else { keys[provider] = trimmed }
        write(keys)
        return true
    }

    @discardableResult
    static func remove(for provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var keys = read()
        guard keys.removeValue(forKey: provider) != nil else { return false }
        write(keys)
        return true
    }

    /// Whether the file is readable by anybody but its owner, so the settings
    /// pane can say so rather than assume.
    static func isPrivate() -> Bool {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        else { return true }
        return mode.int16Value & 0o077 == 0
    }

    /// A rough shape test, so an obviously wrong paste is refused before a
    /// request is made. Deliberately loose: every provider names its keys
    /// differently, and a rule tight enough to catch them all would reject the
    /// next one. A real key is never printed back to say what was wrong.
    static func looksLikeAKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 12 && !trimmed.contains(" ") && !trimmed.contains("\n")
    }
}
