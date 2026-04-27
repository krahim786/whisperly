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
        if status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        if status != errSecItemNotFound {
            logger.error("SecItemCopyMatching failed for \(key, privacy: .public): \(status)")
        }
        // Fall back to a bundled key (set at archive time for family-share
        // builds — see BundledKeys.swift). nil for normal dev builds.
        return bundledFallback(for: key)
    }

    /// Returns a build-bundled key when no Keychain entry exists. User-saved
    /// Keychain entries always take precedence so a family member can swap in
    /// their own key without rebuilding.
    private func bundledFallback(for key: String) -> String? {
        switch key {
        case Self.groqAPIKey:
            return BundledKeys.groqAPIKey?.isEmpty == false ? BundledKeys.groqAPIKey : nil
        case Self.anthropicAPIKey:
            return BundledKeys.anthropicAPIKey?.isEmpty == false ? BundledKeys.anthropicAPIKey : nil
        default:
            return nil
        }
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
