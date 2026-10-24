import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Passwords and access tokens are
/// stored per server account and never written to disk in plain text.
enum Keychain {
    private static let service = "com.zmf.theatersplus"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func tokenKey(_ id: UUID) -> String { "token.\(id.uuidString)" }
    static func passwordKey(_ id: UUID) -> String { "password.\(id.uuidString)" }

    /// Stable per-install device id reported to Jellyfin sessions.
    static var deviceId: String {
        if let existing = get("deviceId") { return existing }
        let fresh = UUID().uuidString
        set(fresh, for: "deviceId")
        return fresh
    }
}
