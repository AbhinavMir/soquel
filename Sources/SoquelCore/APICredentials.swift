import Foundation
import Security

/// The keys for Clean This Folder, one per provider, kept in the Keychain.
///
/// Not in `settings.json`. That file is plain text, documented as something to
/// edit by hand, opened in an editor from the View menu, and it is the file
/// somebody pastes into a bug report. A key belongs somewhere the operating
/// system already protects.
enum APICredentials {
    private static let service = "app.soquel.Soquel.clean"

    /// One entry per provider, so switching from a hosted service to a local
    /// one and back does not mean pasting a key again.
    private static func account(_ provider: String) -> String { "api-key.\(provider)" }

    /// Whether a key is stored, without reading it. The settings pane asks this
    /// rather than fetching a secret it only wants to count.
    static func isSet(for provider: String) -> Bool {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func key(for provider: String) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    @discardableResult
    static func store(_ key: String, for provider: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(for: provider) }
        remove(for: provider)
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(for provider: String) -> Bool {
        SecItemDelete(baseQuery(provider) as CFDictionary) == errSecSuccess
    }

    private static func baseQuery(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(provider)]
    }

    /// A rough shape test, so an obviously wrong paste is refused before a
    /// request is made. Deliberately loose: every provider names its keys
    /// differently, and a rule tight enough to catch them all would reject the
    /// next one. A real key is never printed back to say what was wrong.
    static func looksLikeAKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 12
            && !trimmed.contains(" ")
            && !trimmed.contains("\n")
    }
}
