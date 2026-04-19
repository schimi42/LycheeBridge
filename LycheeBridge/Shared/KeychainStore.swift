import Foundation
import Security

struct KeychainStore {
    private static let lycheeService = "LycheeBridge.LycheeCredentials"
    private static let openAIService = "LycheeBridge.OpenAICredentials"
    private static let defaultAccount = "default"

    func save(password: String) throws {
        try saveSecret(password, service: Self.lycheeService, account: Self.defaultAccount)
    }

    func loadPassword() throws -> String {
        try loadSecret(service: Self.lycheeService, account: Self.defaultAccount)
    }

    func saveOpenAIAPIKey(_ apiKey: String) throws {
        try saveSecret(apiKey, service: Self.openAIService, account: Self.defaultAccount)
    }

    func loadOpenAIAPIKey() throws -> String {
        try loadSecret(service: Self.openAIService, account: Self.defaultAccount)
    }

    private func saveSecret(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = query.merging([
            kSecValueData as String: data
        ]) { _, new in new }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    private func loadSecret(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return ""
        }

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandled(status)
        }

        return password
    }
}

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandled(status):
            return "Keychain operation failed with OSStatus \(status)."
        }
    }
}
