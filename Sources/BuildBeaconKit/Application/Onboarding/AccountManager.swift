import Foundation

public enum AccountManagementError: Error, Hashable, Sendable {
    case invalidCredential
    case noConnectedAccount
    case monitorBelongsToAnotherAccount
    case rollbackFailed
}

public actor AccountManager {
    private let service: any BitbucketService
    private let credentialStore: any CredentialStore
    private let configurationStore: any ConfigurationStore
    private let lifecycle: (any AccountLifecycleControlling)?

    public init(
        service: any BitbucketService,
        credentialStore: any CredentialStore,
        configurationStore: any ConfigurationStore,
        lifecycle: (any AccountLifecycleControlling)? = nil
    ) {
        self.service = service
        self.credentialStore = credentialStore
        self.configurationStore = configurationStore
        self.lifecycle = lifecycle
    }

    @discardableResult
    public func connect(using credential: AccountCredential) async throws -> AccountProfile {
        guard !credential.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountManagementError.invalidCredential
        }
        let profile = try await service.validate(credential: credential)
        let oldConfiguration = try await configurationStore.load()
        let replacedCredential = try await credentialStore.load(accountID: profile.id)
        let displacedCredential: AccountCredential?
        if let oldAccount = oldConfiguration.account, oldAccount.id != profile.id {
            displacedCredential = try await credentialStore.load(accountID: oldAccount.id)
        } else {
            displacedCredential = nil
        }
        let changesAccount = oldConfiguration.account?.id != profile.id

        if changesAccount { await lifecycle?.invalidateForAccountChange() }
        do {
            try await credentialStore.save(credential, accountID: profile.id)
            var updated = oldConfiguration
            updated.account = profile
            if changesAccount { updated.monitors = [] }
            try await configurationStore.save(updated)
            if let oldAccount = oldConfiguration.account, oldAccount.id != profile.id {
                try await credentialStore.delete(accountID: oldAccount.id)
            }
        } catch {
            let primaryError = error
            var rollbackDidFail = false
            do {
                if let replacedCredential {
                    try await credentialStore.save(replacedCredential, accountID: profile.id)
                } else {
                    try await credentialStore.delete(accountID: profile.id)
                }
            } catch {
                rollbackDidFail = true
            }
            if let oldAccount = oldConfiguration.account, let displacedCredential {
                do {
                    try await credentialStore.save(displacedCredential, accountID: oldAccount.id)
                } catch {
                    rollbackDidFail = true
                }
            }
            do {
                try await configurationStore.save(oldConfiguration)
            } catch {
                rollbackDidFail = true
            }
            if changesAccount { await lifecycle?.configurationDidChange() }
            if rollbackDidFail { throw AccountManagementError.rollbackFailed }
            throw primaryError
        }
        await lifecycle?.configurationDidChange()
        return profile
    }

    public func disconnect() async throws {
        let oldConfiguration = try await configurationStore.load()
        guard let account = oldConfiguration.account else { throw AccountManagementError.noConnectedAccount }
        let oldCredential = try await credentialStore.load(accountID: account.id)

        await lifecycle?.invalidateForAccountChange()
        do {
            try await credentialStore.delete(accountID: account.id)
        } catch {
            await lifecycle?.configurationDidChange()
            throw error
        }
        do {
            var updated = oldConfiguration
            updated.account = nil
            updated.monitors = []
            try await configurationStore.save(updated)
        } catch {
            let primaryError = error
            var rollbackDidFail = false
            do {
                if let oldCredential { try await credentialStore.save(oldCredential, accountID: account.id) }
            } catch {
                rollbackDidFail = true
            }
            await lifecycle?.configurationDidChange()
            if rollbackDidFail { throw AccountManagementError.rollbackFailed }
            throw primaryError
        }
        await lifecycle?.configurationDidChange()
    }

    public func configureMonitors(_ monitors: [MonitorConfiguration]) async throws {
        var configuration = try await configurationStore.load()
        guard let account = configuration.account else { throw AccountManagementError.noConnectedAccount }
        guard monitors.allSatisfy({ $0.id.accountID == account.id }) else {
            throw AccountManagementError.monitorBelongsToAnotherAccount
        }

        var seen = Set<MonitorID>()
        configuration.monitors = monitors.filter { seen.insert($0.id).inserted }
        try await configurationStore.save(configuration)
        await lifecycle?.configurationDidChange()
    }

    public func configuration() async throws -> AppConfiguration {
        try await configurationStore.load()
    }
}
