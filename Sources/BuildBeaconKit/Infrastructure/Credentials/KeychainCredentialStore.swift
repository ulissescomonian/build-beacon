import Foundation
import Security

public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case invalidCredentialData
    case unexpectedStatus(Int32)
}

/// Stores account credentials as non-synchronizable, device-local Keychain items.
///
/// No plaintext fallback is provided intentionally. A Keychain failure must remain
/// visible to the caller so a connection or logout transaction can be rolled back.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    public let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.buildbeacon.credentials") {
        self.service = service
    }

    public func save(_ credential: AccountCredential, accountID: AccountID) async throws {
        let encoded = try encode(credential)
        let query = baseQuery(accountID: accountID)
        var attributes = writeAttributes(data: encoded)

        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Accessibility is included so an item created by an older build is
            // tightened during an ordinary credential rotation.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func load(accountID: AccountID) async throws -> AccountCredential? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainCredentialStoreError.invalidCredentialData
            }
            return try decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func delete(accountID: AccountID) async throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountID: AccountID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func writeAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }

    private func encode(_ credential: AccountCredential) throws -> Data {
        do {
            return try JSONEncoder().encode(StoredCredential(email: credential.email, token: credential.token))
        } catch {
            throw KeychainCredentialStoreError.invalidCredentialData
        }
    }

    private func decode(_ data: Data) throws -> AccountCredential {
        do {
            let stored = try JSONDecoder().decode(StoredCredential.self, from: data)
            return AccountCredential(email: stored.email, token: stored.token)
        } catch {
            throw KeychainCredentialStoreError.invalidCredentialData
        }
    }
}

private struct StoredCredential: Codable {
    let email: String
    let token: String
}
