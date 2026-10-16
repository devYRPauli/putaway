import Foundation
import Security

/// API keys live in the login Keychain, one item per provider. The provider's environment variable overrides it for scripts.
public enum KeyStore {
    static func query(_ provider: Provider) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "putaway",
        kSecAttrAccount as String: provider.rawValue,
    ] }

    public static func load(_ provider: Provider) throws -> String? {
        if let key = ProcessInfo.processInfo.environment[provider.environmentKey], !key.isEmpty { return key }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(provider).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func save(_ key: String, for provider: Provider) throws {
        SecItemDelete(query(provider) as CFDictionary)
        let status = SecItemAdd(query(provider).merging([kSecValueData as String: Data(key.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func keychainError(_ status: OSStatus) -> PutawayError {
        PutawayError(errorDescription: "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
    }
}
