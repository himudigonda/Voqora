import Foundation
import Security

nonisolated struct KeychainKey: Hashable, Sendable {
    let rawValue: String

    static let sessionToken = KeychainKey(rawValue: "com.himudigonda.Voqora.session_token")
    static let refreshToken = KeychainKey(rawValue: "com.himudigonda.Voqora.refresh_token")

    static func llmAPIKey(_ provider: LLMProvider) -> KeychainKey {
        if provider == .google {
            return KeychainKey(rawValue: "com.himudigonda.Voqora.gemini_api_key")
        }
        return KeychainKey(rawValue: "com.himudigonda.Voqora.llm_api_key.\(provider.rawValue)")
    }

    static var allCases: [KeychainKey] {
        [.sessionToken, .refreshToken] + LLMProvider.allCases.map(llmAPIKey)
    }
}

nonisolated enum KeychainService {
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private static func baseQuery(_ key: KeychainKey, service: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        return query
    }

    @discardableResult
    static func set(_ value: String, for key: KeychainKey, service: String? = nil) -> Bool {
        let query = baseQuery(key, service: service)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: KeychainKey, service: String? = nil) -> String? {
        var query = baseQuery(key, service: service)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        migrateAccessibility(of: item, key: key, service: service)
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: KeychainKey, service: String? = nil) -> Bool {
        let status = SecItemDelete(baseQuery(key, service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: KeychainKey, service: String? = nil) -> Bool {
        var query = baseQuery(key, service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func needsAccessibilityMigration(_ attributes: [String: Any]) -> Bool {
        guard let reported = attributes[kSecAttrAccessible as String] as? String else { return false }
        return reported != (accessibility as String)
    }

    static func migrateAccessibility(of attributes: [String: Any], key: KeychainKey, service: String?) {
        guard needsAccessibilityMigration(attributes) else { return }
        SecItemUpdate(
            baseQuery(key, service: service) as CFDictionary,
            [kSecAttrAccessible as String: accessibility] as CFDictionary
        )
    }
}
