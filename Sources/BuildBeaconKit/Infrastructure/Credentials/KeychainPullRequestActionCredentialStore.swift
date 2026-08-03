import Foundation
import Security

public struct PullRequestActionCredentialRecord: Sendable {
    public let credential: AccountCredential
    public let expectedAccountID: AccountID

    public init(credential: AccountCredential, expectedAccountID: AccountID) {
        self.credential = credential
        self.expectedAccountID = expectedAccountID
    }
}

public protocol PullRequestActionCredentialStoring: Sendable {
    func save(_ record: PullRequestActionCredentialRecord) async throws
    func load() async throws -> PullRequestActionCredentialRecord?
    func exists() async throws -> Bool
    func delete() async throws
}

public extension PullRequestActionCredentialStoring {
    func exists() async throws -> Bool { try await load() != nil }
}

/// Stores the optional write-capable pull request token independently from the
/// read-only monitoring token. The fixed Keychain account prevents a caller
/// from accidentally addressing this credential through a monitoring account.
public struct KeychainPullRequestActionCredentialStore: PullRequestActionCredentialStoring, Sendable {
    public static let defaultService = "com.epyczones.buildbeacon.bitbucket-pr-actions-token"

    public let service: String
    private let keychainAccount = "pull-request-actions"

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func save(_ record: PullRequestActionCredentialRecord) async throws {
        let encoded = try encode(record)
        let query = baseQuery()
        var attributes = writeAttributes(data: encoded)

        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func load() async throws -> PullRequestActionCredentialRecord? {
        var query = baseQuery()
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

    public func exists() async throws -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func delete() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func writeAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }

    private func encode(_ record: PullRequestActionCredentialRecord) throws -> Data {
        do {
            return try JSONEncoder().encode(StoredPullRequestActionCredential(
                email: record.credential.email,
                token: record.credential.token,
                expectedAccountID: record.expectedAccountID.rawValue
            ))
        } catch {
            throw KeychainCredentialStoreError.invalidCredentialData
        }
    }

    private func decode(_ data: Data) throws -> PullRequestActionCredentialRecord {
        do {
            let stored = try JSONDecoder().decode(StoredPullRequestActionCredential.self, from: data)
            guard !stored.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !stored.token.isEmpty,
                  !stored.expectedAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeychainCredentialStoreError.invalidCredentialData
            }
            return PullRequestActionCredentialRecord(
                credential: AccountCredential(email: stored.email, token: stored.token),
                expectedAccountID: AccountID(rawValue: stored.expectedAccountID)
            )
        } catch let error as KeychainCredentialStoreError {
            throw error
        } catch {
            throw KeychainCredentialStoreError.invalidCredentialData
        }
    }
}

private struct StoredPullRequestActionCredential: Codable {
    let email: String
    let token: String
    let expectedAccountID: String
}
