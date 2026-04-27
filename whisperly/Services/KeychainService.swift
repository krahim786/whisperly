import Foundation
import Security
import os

/// Stores API keys in the macOS Keychain under service `com.karim.whisperly`.
/// Uses generic password items keyed by account name.
nonisolated final class KeychainService: Sendable {
    static let groqAPIKey = "groq_api_key"
    static let anthropicAPIKey = "anthropic_api_key"

    private let service = "com.karim.whisperly"
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "Keychain")

    func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing first to avoid duplicate-item errors.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd failed for \(key, privacy: .public): \(status)")
        }
    }

    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.error("SecItemCopyMatching failed for \(key, privacy: .public): \(status)")
            }
            return nil
        }
        return value
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
