import Foundation
import Security

/// The SubQ key lives in the login Keychain. SUBQ_API_KEY overrides it for scripts.
public enum KeyStore {
    static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "putaway",
        kSecAttrAccount as String: "subq",
    ] }

    public static func load() throws -> String? {
        if let key = ProcessInfo.processInfo.environment["SUBQ_API_KEY"], !key.isEmpty { return key }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(key.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func keychainError(_ status: OSStatus) -> PutawayError {
        PutawayError(errorDescription: "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
    }
}
