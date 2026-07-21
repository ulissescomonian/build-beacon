import XCTest
@testable import BuildBeaconKit

final class AccountManagerTests: XCTestCase, @unchecked Sendable {
    func testConnectCommitsCredentialThenConfiguration() async throws {
        let stores = AccountTestStores(configuration: AppConfiguration())
        let lifecycle = LifecycleSpy()
        let manager = AccountManager(
            service: AccountTestService(), credentialStore: stores,
            configurationStore: stores, lifecycle: lifecycle
        )

        let profile = try await manager.connect(using: AccountCredential(email: "person@example.com", token: "secret"))
        let token = await stores.savedToken(accountID: profile.id)
        let savedConfiguration = try await stores.load()
        let lifecycleEvents = await lifecycle.events
        XCTAssertEqual(profile.id, AccountID(rawValue: "new-account"))
        XCTAssertEqual(token, "secret")
        XCTAssertEqual(savedConfiguration.account, profile)
        XCTAssertEqual(lifecycleEvents, ["invalidate", "changed"])
    }

    func testConnectRollsCredentialBackWhenConfigurationCommitFails() async {
        let stores = AccountTestStores(configuration: AppConfiguration(), failNextSave: true)
        let manager = AccountManager(
            service: AccountTestService(), credentialStore: stores, configurationStore: stores
        )

        do {
            _ = try await manager.connect(using: AccountCredential(email: "person@example.com", token: "secret"))
            XCTFail("Expected connection failure")
        } catch { }
        let token = await stores.savedToken(accountID: AccountID(rawValue: "new-account"))
        let savedConfiguration = try? await stores.load()
        XCTAssertNil(token)
        XCTAssertNil(savedConfiguration?.account)
    }

    func testDisconnectDoesNotPublishLogoutWhenCredentialDeletionFails() async {
        let profile = AccountProfile(id: AccountID(rawValue: "new-account"), displayName: "Person", email: "person@example.com")
        let stores = AccountTestStores(configuration: AppConfiguration(account: profile), failDelete: true)
        await stores.seed(AccountCredential(email: profile.email, token: "old"), accountID: profile.id)
        let manager = AccountManager(
            service: AccountTestService(), credentialStore: stores, configurationStore: stores
        )

        do {
            try await manager.disconnect()
            XCTFail("Expected deletion failure")
        } catch { }
        let savedConfiguration = try? await stores.load()
        let token = await stores.savedToken(accountID: profile.id)
        XCTAssertEqual(savedConfiguration?.account, profile)
        XCTAssertEqual(token, "old")
    }

    func testMonitorConfigurationDeduplicatesAndRejectsForeignAccount() async throws {
        let profile = AccountProfile(id: AccountID(rawValue: "new-account"), displayName: "Person", email: "person@example.com")
        let stores = AccountTestStores(configuration: AppConfiguration(account: profile))
        let manager = AccountManager(
            service: AccountTestService(), credentialStore: stores, configurationStore: stores
        )
        let own = monitor(accountID: profile.id, repository: "one")
        try await manager.configureMonitors([own, own])
        let savedConfiguration = try await stores.load()
        XCTAssertEqual(savedConfiguration.monitors, [own])

        do {
            try await manager.configureMonitors([monitor(accountID: AccountID(rawValue: "other"), repository: "two")])
            XCTFail("Expected ownership validation")
        } catch let error as AccountManagementError {
            XCTAssertEqual(error, .monitorBelongsToAnotherAccount)
        }
    }

    private func monitor(accountID: AccountID, repository: String) -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: accountID,
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: repository),
                target: .defaultBranch
            ),
            workspaceSlug: "workspace", workspaceName: "Workspace",
            repositorySlug: repository, repositoryName: repository
        )
    }
}

private struct AccountTestService: BitbucketService {
    func validate(credential: AccountCredential) async throws -> AccountProfile {
        AccountProfile(id: AccountID(rawValue: "new-account"), displayName: "Person", email: credential.email)
    }
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] { [] }
    func listRepositories(in workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo] { [] }
    func listBranches(in repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo] { [] }
    func latestPipeline(for monitor: MonitorConfiguration) async throws -> PipelineRun? { nil }
}

private actor AccountTestStores: CredentialStore, ConfigurationStore {
    enum Failure: Error { case intentional }
    private var configuration: AppConfiguration
    private var credentials: [AccountID: AccountCredential] = [:]
    private var failNextSave: Bool
    private let failDelete: Bool

    init(configuration: AppConfiguration, failNextSave: Bool = false, failDelete: Bool = false) {
        self.configuration = configuration
        self.failNextSave = failNextSave
        self.failDelete = failDelete
    }

    func seed(_ credential: AccountCredential, accountID: AccountID) { credentials[accountID] = credential }
    func savedToken(accountID: AccountID) -> String? { credentials[accountID]?.token }
    func save(_ credential: AccountCredential, accountID: AccountID) async throws { credentials[accountID] = credential }
    func load(accountID: AccountID) async throws -> AccountCredential? { credentials[accountID] }
    func delete(accountID: AccountID) async throws {
        if failDelete { throw Failure.intentional }
        credentials[accountID] = nil
    }
    func load() async throws -> AppConfiguration { configuration }
    func save(_ configuration: AppConfiguration) async throws {
        if failNextSave {
            failNextSave = false
            throw Failure.intentional
        }
        self.configuration = configuration
    }
    func reset() async throws { configuration = AppConfiguration() }
}

private actor LifecycleSpy: AccountLifecycleControlling {
    private(set) var events: [String] = []
    func invalidateForAccountChange() { events.append("invalidate") }
    func configurationDidChange() { events.append("changed") }
}
