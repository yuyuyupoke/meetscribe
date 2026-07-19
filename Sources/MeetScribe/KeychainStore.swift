import Foundation
import Security

/// macOS Keychain を使ってプロバイダー別の API Key を安全に保存する。
enum KeychainStore {
    static let service = "com.meetscribe.app"
    /// 既存セットアップスクリプトとの互換用。OpenAI account は変更しない。
    static let account = AIProvider.openAI.keychainAccount

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain保存失敗: \(status)"
            }
        }
    }

    static func save(_ value: String, for provider: AIProvider) throws {
        let data = Data(value.utf8)

        // 既存エントリ削除（上書き）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func read(for provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func hasAPIKey(for provider: AIProvider) -> Bool {
        guard let value = read(for: provider) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - OpenAI互換API

    /// 既存の利用箇所・セットアップスクリプトとのソース互換を維持する。
    static func save(_ value: String) throws { try save(value, for: .openAI) }
    static func read() -> String? { read(for: .openAI) }
    static var hasAPIKey: Bool { hasAPIKey(for: .openAI) }
}
