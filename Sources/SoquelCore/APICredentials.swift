import Foundation
import Security

/// The key for Clean This Folder, kept in the Keychain.
///
/// Not in `settings.json`. That file is plain text, documented as something to
/// edit by hand, opened in an editor from the View menu, and it is the file
/// somebody pastes into a bug report. A key belongs somewhere the operating
/// system already protects.
enum APICredentials {
    private static let service = "app.soquel.Soquel.anthropic"
    private static let account = "api-key"

    /// Whether a key is stored, without reading it. The settings pane asks this
    /// rather than fetching a secret it only wants to count.
    static var isSet: Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func key() -> String? {
        var query = baseQuery()
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
    static func store(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove() }
        remove()
        var query = baseQuery()
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        SecItemDelete(baseQuery() as CFDictionary) == errSecSuccess
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// A rough shape test, so a pasted word is refused before a request is made
    /// and a real key is never printed back to say what was wrong.
    static func looksLikeAKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 20
    }
}
