// KeychainStore.swift
// brain-ios
//
// Thin wrapper around the iOS Keychain (Security framework) for the
// handful of secrets the app needs to persist: API key, server URL,
// user id. Each value is keyed by an `account` string under a single
// service identifier so they share access controls but stay separable.
//
// Keychain operations are synchronous; we don't bother making this an
// actor because it's only ever called from app-launch / settings code,
// not from hot paths. M32 will use this from the login flow.

import Foundation
import Security

enum KeychainAccount: String {
    case apiKey      = "io.mindkeeper.brain.apiKey"
    case apiKeyId    = "io.mindkeeper.brain.apiKeyId"
    case serverURL   = "io.mindkeeper.brain.serverURL"
    case userId      = "io.mindkeeper.brain.userId"
    case userEmail   = "io.mindkeeper.brain.userEmail"
}

enum KeychainError: Error, CustomStringConvertible {
    case unexpectedData
    case osStatus(OSStatus)

    var description: String {
        switch self {
        case .unexpectedData:
            return "Keychain returned data in an unexpected format"
        case .osStatus(let status):
            // SecCopyErrorMessageString gives a human-readable message on real
            // devices; falls back to the numeric code if not available.
            if let cfMessage = SecCopyErrorMessageString(status, nil) {
                return "Keychain error: \(cfMessage as String) (\(status))"
            }
            return "Keychain error: \(status)"
        }
    }
}

struct KeychainStore {

    /// Service identifier all entries share. Keeping it constant means
    /// a future "wipe everything" pass can issue one delete call.
    private static let service = "io.mindkeeper.brain"

    // MARK: - Public API

    static func save(_ value: String, for account: KeychainAccount) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try saveData(data, for: account)
    }

    static func load(_ account: KeychainAccount) throws -> String? {
        guard let data = try loadData(account) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    static func delete(_ account: KeychainAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// Wipe every entry under our service. Useful on logout.
    static func wipe() throws {
        for account in [
            KeychainAccount.apiKey,
            .apiKeyId,
            .serverURL,
            .userId,
            .userEmail,
        ] {
            try delete(account)
        }
    }

    // MARK: - Internals

    private static func saveData(_ data: Data, for account: KeychainAccount) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]

        // Try update first; if no item exists, fall back to add. Avoids
        // the "two-call dance" with errSecDuplicateItem on every save.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        default:
            throw KeychainError.osStatus(updateStatus)
        }
    }

    private static func loadData(_ account: KeychainAccount) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }
}
