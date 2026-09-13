import Foundation
import Security

/// Keychain errors surfaced by the helper.
enum KeychainError: LocalizedError {
    case conversionFailed
    case unexpectedStatus(OSStatus)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .conversionFailed: return "Failed to convert data to/from string."
        case .unexpectedStatus(let s): return "Keychain returned status: \(s)."
        case .itemNotFound: return "No API Key found in Keychain."
        }
    }
}

/// Lightweight async Keychain helper. Methods are async/throws to support background execution
/// and clearer error propagation.
final class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    private let service: String = Bundle.main.bundleIdentifier ?? "twigin"
    private let account: String = "QWenAPIKey"

    /// Save API key to Keychain. Pass an empty string to delete the key.
    func save(apiKey: String) async throws {
        if apiKey.isEmpty {
            try deleteApiKey()
            return
        }

        guard let data = apiKey.data(using: .utf8) else { throw KeychainError.conversionFailed }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let attributes: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
            if status != errSecSuccess {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        throw KeychainError.unexpectedStatus(status)
    }

    /// Retrieve the stored API key, or throw if not found.
    func getApiKey() async throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(status)
        }
        return str
    }

    /// Delete stored API key. Throws on failure (except item not found).
    func deleteApiKey() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
