import AppKit
import BuildBeaconKit
import BuildBeaconUI
import Foundation
import OSLog

actor SnapshotRelay {
    private let notificationSender: any NotificationSending
    private let historyPersistence: SnapshotPersistenceCoordinator?
    private var sink: (@Sendable (MonitoringSnapshot) -> Void)?
    private var generation: UInt64 = 0
    private var acceptsPublications = true

    init(
        notificationSender: any NotificationSending,
        historyPersistence: SnapshotPersistenceCoordinator? = nil
    ) {
        self.notificationSender = notificationSender
        self.historyPersistence = historyPersistence
    }

    func install(_ sink: @escaping @Sendable (MonitoringSnapshot) -> Void) {
        self.sink = sink
    }

    func suspend() {
        generation &+= 1
        acceptsPublications = false
    }

    func resume() {
        generation &+= 1
        acceptsPublications = true
    }

    func publish(snapshot: MonitoringSnapshot, events: [NotificationEvent]) async {
        guard acceptsPublications else { return }
        if let historyPersistence {
            // Keep history writes ordered with account/monitor purge operations. The
            // coordinator handles persistence failures internally, so this never
            // withholds snapshot delivery because of a local disk error.
            await historyPersistence.persist(snapshot)
        }
        let publicationGeneration = generation
        for event in events {
            guard acceptsPublications, publicationGeneration == generation else { return }
            do {
                try await notificationSender.deliver(event)
            } catch {
                BuildBeaconLog.notifications.error(
                    "Notification delivery failed: \(LogRedactor.redact(error.localizedDescription), privacy: .private)"
                )
            }
        }
        guard acceptsPublications, publicationGeneration == generation else { return }
        sink?(snapshot)
    }
}

@MainActor
final class ProductionRuntime: BuildBeaconRuntime {
    private let credentialStore: KeychainCredentialStore
    private let configurationStore: JSONConfigurationStore
    private let notificationService: UserNotificationService
    private let historyPersistence: SnapshotPersistenceCoordinator
    private let bitbucket: BitbucketClient
    private let relay: SnapshotRelay
    private let monitoringEngine: MonitoringEngine
    private let accountManager: AccountManager
    private let loginItemService: LoginItemService
    private let linkOpener: SafeLinkOpener

    init() throws {
        let credentialStore = KeychainCredentialStore(
            service: "com.epyczones.buildbeacon.bitbucket-api-token"
        )
        let configurationStore = try JSONConfigurationStore(directoryName: "BuildBeacon")
        let historyStore = try JSONPipelineHistoryStore(directoryName: "BuildBeacon")
        let ledger = try NotificationLedger(directoryName: "BuildBeacon")
        let notificationService = UserNotificationService(ledger: ledger)
        let bitbucket = BitbucketClient(credentialStore: credentialStore)
        let historyPersistence = SnapshotPersistenceCoordinator(
            historyStore: historyStore,
            configurationStore: configurationStore
        )
        let relay = SnapshotRelay(
            notificationSender: notificationService,
            historyPersistence: historyPersistence
        )
        let monitoringEngine = MonitoringEngine(
            service: bitbucket,
            configurationStore: configurationStore,
            concurrencyLimit: 4
        ) { snapshot, _, events in
            await relay.publish(snapshot: snapshot, events: events)
        }
        let accountManager = AccountManager(
            service: bitbucket,
            credentialStore: credentialStore,
            configurationStore: configurationStore,
            lifecycle: monitoringEngine
        )

        self.credentialStore = credentialStore
        self.configurationStore = configurationStore
        self.notificationService = notificationService
        self.historyPersistence = historyPersistence
        self.bitbucket = bitbucket
        self.relay = relay
        self.monitoringEngine = monitoringEngine
        self.accountManager = accountManager
        self.loginItemService = LoginItemService()
        self.linkOpener = SafeLinkOpener()
    }

    func loadConfiguration() async throws -> AppConfiguration {
        try await configurationStore.load()
    }

    func connect(email: String, token: String) async throws -> AppConfiguration {
        let previousConfiguration = try await accountManager.configuration()
        await relay.suspend()
        let updatedConfiguration: AppConfiguration
        do {
            _ = try await accountManager.connect(using: AccountCredential(email: email, token: token))
            updatedConfiguration = try await accountManager.configuration()
        } catch {
            await relay.resume()
            throw error
        }

        if let previousAccount = previousConfiguration.account,
           previousAccount.id != updatedConfiguration.account?.id {
            for monitor in previousConfiguration.monitors {
                await notificationService.removePending(for: monitor.id)
            }
            await historyPersistence.removeAll(for: previousAccount.id)
        }
        await relay.resume()
        await monitoringEngine.start()
        return updatedConfiguration
    }

    func revalidate() async throws -> AppConfiguration {
        var configuration = try await accountManager.configuration()
        guard let account = configuration.account,
              let credential = try await credentialStore.load(accountID: account.id) else {
            throw ObservationFailure.invalidCredentials
        }
        configuration.account = try await bitbucket.validate(credential: credential)
        try await configurationStore.save(configuration)
        await monitoringEngine.configurationDidChange()
        return configuration
    }

    func disconnect() async throws -> AppConfiguration {
        let oldConfiguration = try await accountManager.configuration()
        await relay.suspend()
        do {
            try await accountManager.disconnect()
        } catch {
            await relay.resume()
            throw error
        }
        for monitor in oldConfiguration.monitors {
            await notificationService.removePending(for: monitor.id)
        }
        if let account = oldConfiguration.account {
            await historyPersistence.removeAll(for: account.id)
        }
        await relay.resume()
        return try await accountManager.configuration()
    }

    func startMonitoring(_ sink: @escaping @Sendable (MonitoringSnapshot) -> Void) async {
        await relay.install(sink)
        do {
            try await notificationService.configureCategories()
        } catch {
            BuildBeaconLog.notifications.error(
                "Unable to configure notification categories: \(LogRedactor.redact(error.localizedDescription), privacy: .private)"
            )
        }
        await monitoringEngine.start()
        if let snapshot = await monitoringEngine.latestSnapshot {
            sink(snapshot)
        }
    }

    func refresh(reason: RefreshReason) async -> MonitoringSnapshot? {
        await monitoringEngine.refresh(reason: reason)
        return await monitoringEngine.latestSnapshot
    }

    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] {
        try await bitbucket.listWorkspaces(accountID: accountID)
    }

    func listRepositories(
        workspace: WorkspaceInfo,
        accountID: AccountID
    ) async throws -> [RepositoryInfo] {
        try await bitbucket.listRepositories(in: workspace, accountID: accountID)
    }

    func listBranches(
        repository: RepositoryInfo,
        accountID: AccountID
    ) async throws -> [BranchInfo] {
        try await bitbucket.listBranches(in: repository, accountID: accountID)
    }

    func setMonitors(_ monitors: [MonitorConfiguration]) async throws -> AppConfiguration {
        let previous = try await accountManager.configuration()
        try await accountManager.configureMonitors(monitors)
        let retained = Set(monitors.map(\.id))
        for removed in previous.monitors where !retained.contains(removed.id) {
            await notificationService.removePending(for: removed.id)
            await historyPersistence.removeEntries(for: removed.id)
        }
        return try await accountManager.configuration()
    }

    func saveConfiguration(_ configuration: AppConfiguration) async throws -> AppConfiguration {
        let previous = try await configurationStore.load()
        if configuration.notificationsEnabled && !previous.notificationsEnabled {
            let permission = try await notificationService.requestAuthorization()
            guard permission.authorization == .authorized
                    || permission.authorization == .provisional
                    || permission.authorization == .ephemeral else {
                throw UserNotificationServiceError.authorizationDenied
            }
        }
        try await configurationStore.save(configuration)
        if requiresMonitoringReconfiguration(from: previous, to: configuration) {
            await monitoringEngine.configurationDidChange()
        }
        return try await configurationStore.load()
    }

    func saveUnseenActivity(
        _ markers: [MonitorActivityMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        try await configurationStore.saveUnseenActivity(markers, for: accountID)
    }

    func saveApprovalWaits(
        _ markers: [ApprovalWaitMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        try await configurationStore.saveApprovalWaits(markers, for: accountID)
    }

    /// Activity markers only affect the presentation of newly observed work.
    /// Persisting them must not interrupt or reschedule the independent monitoring loop.
    private func requiresMonitoringReconfiguration(
        from previous: AppConfiguration,
        to configuration: AppConfiguration
    ) -> Bool {
        var normalizedPrevious = previous
        normalizedPrevious.unseenActivity = []
        normalizedPrevious.approvalWaits = []
        normalizedPrevious.approvalReminderInterval = .none
        var normalizedConfiguration = configuration
        normalizedConfiguration.unseenActivity = []
        normalizedConfiguration.approvalWaits = []
        normalizedConfiguration.approvalReminderInterval = .none
        return normalizedPrevious != normalizedConfiguration
    }

    func history(for monitorID: MonitorID) async throws -> [PipelineHistoryEntry] {
        await historyPersistence.entries(for: monitorID)
    }

    func clearHistory(for monitorID: MonitorID) async throws {
        await historyPersistence.removeEntries(for: monitorID)
    }

    func notificationPermissionStatus() async throws -> NotificationPermissionStatus {
        try await notificationService.permissionStatus()
    }

    func requestNotificationPermission() async throws -> NotificationPermissionStatus {
        try await notificationService.requestAuthorization()
    }

    func sendTestNotification(route: NotificationRoute) async throws {
        try await notificationService.deliverTest(route: route)
    }

    func reconcileApprovalReminders(
        activeApprovals: [ApprovalWaitMarker],
        interval: ApprovalReminderInterval
    ) async {
        await notificationService.reconcileApprovalReminders(
            activeApprovals: activeApprovals,
            interval: interval
        )
    }

    func openNotificationSettings() throws {
        guard let systemSettingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            throw SafeLinkError.systemRejectedURL
        }
        NSWorkspace.shared.openApplication(
            at: systemSettingsURL,
            configuration: .init()
        )
    }

    func openPipeline(_ observation: MonitorObservation) throws {
        guard let buildNumber = observation.lastKnownRun?.buildNumber else {
            throw SafeLinkError.malformedURL
        }
        try openPipeline(monitor: observation.monitor, buildNumber: buildNumber)
    }

    func openPipeline(monitor: MonitorConfiguration, buildNumber: Int) throws {
        guard buildNumber > 0 else { throw SafeLinkError.malformedURL }
        let url = URL(string: "https://bitbucket.org")!
            .appendingPathComponent(monitor.workspaceSlug)
            .appendingPathComponent(monitor.repositorySlug)
            .appendingPathComponent("pipelines")
            .appendingPathComponent("results")
            .appendingPathComponent(String(buildNumber))
        try openBitbucketURL(url)
    }

    func openBitbucketURL(_ url: URL) throws {
        try linkOpener.open(url)
    }

    func launchAtLoginEnabled() -> Bool {
        loginItemService.state == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) async throws {
        try await loginItemService.setEnabled(enabled)
    }
}

@MainActor
final class UnavailableRuntime: BuildBeaconRuntime {
    private let failure: Error

    init(failure: Error) {
        self.failure = failure
    }

    func loadConfiguration() async throws -> AppConfiguration { throw failure }
    func connect(email: String, token: String) async throws -> AppConfiguration { throw failure }
    func revalidate() async throws -> AppConfiguration { throw failure }
    func disconnect() async throws -> AppConfiguration { throw failure }
    func startMonitoring(_ sink: @escaping @Sendable (MonitoringSnapshot) -> Void) async {}
    func refresh(reason: RefreshReason) async -> MonitoringSnapshot? { nil }
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] { throw failure }
    func listRepositories(workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo] { throw failure }
    func listBranches(repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo] { throw failure }
    func setMonitors(_ monitors: [MonitorConfiguration]) async throws -> AppConfiguration { throw failure }
    func saveConfiguration(_ configuration: AppConfiguration) async throws -> AppConfiguration { throw failure }
    func saveUnseenActivity(
        _ markers: [MonitorActivityMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration { throw failure }
    func saveApprovalWaits(
        _ markers: [ApprovalWaitMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration { throw failure }
    func history(for monitorID: MonitorID) async throws -> [PipelineHistoryEntry] { throw failure }
    func clearHistory(for monitorID: MonitorID) async throws { throw failure }
    func notificationPermissionStatus() async throws -> NotificationPermissionStatus { throw failure }
    func requestNotificationPermission() async throws -> NotificationPermissionStatus { throw failure }
    func sendTestNotification(route: NotificationRoute) async throws { throw failure }
    func reconcileApprovalReminders(
        activeApprovals: [ApprovalWaitMarker],
        interval: ApprovalReminderInterval
    ) async {}
    func openNotificationSettings() throws { throw failure }
    func openPipeline(_ observation: MonitorObservation) throws { throw failure }
    func openPipeline(monitor: MonitorConfiguration, buildNumber: Int) throws { throw failure }
    func openBitbucketURL(_ url: URL) throws { throw failure }
    func launchAtLoginEnabled() -> Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) async throws { throw failure }
}
