import BuildBeaconKit
import Foundation
import Observation

@MainActor
public protocol BuildBeaconRuntime: AnyObject {
    func loadConfiguration() async throws -> AppConfiguration
    func connect(email: String, token: String) async throws -> AppConfiguration
    func revalidate() async throws -> AppConfiguration
    func disconnect() async throws -> AppConfiguration
    func startMonitoring(_ sink: @escaping @Sendable (MonitoringSnapshot) -> Void) async
    func refresh(reason: RefreshReason) async -> MonitoringSnapshot?
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo]
    func listRepositories(workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo]
    func listBranches(repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo]
    func setMonitors(_ monitors: [MonitorConfiguration]) async throws -> AppConfiguration
    func saveConfiguration(_ configuration: AppConfiguration) async throws -> AppConfiguration
    func saveUnseenActivity(_ markers: [MonitorActivityMarker], for accountID: AccountID) async throws -> AppConfiguration
    func history(for monitorID: MonitorID) async throws -> [PipelineHistoryEntry]
    func clearHistory(for monitorID: MonitorID) async throws
    func notificationPermissionStatus() async throws -> NotificationPermissionStatus
    func requestNotificationPermission() async throws -> NotificationPermissionStatus
    func sendTestNotification(route: NotificationRoute) async throws
    func openNotificationSettings() throws
    func openPipeline(_ observation: MonitorObservation) throws
    func openPipeline(monitor: MonitorConfiguration, buildNumber: Int) throws
    func openBitbucketURL(_ url: URL) throws
    func launchAtLoginEnabled() -> Bool
    func setLaunchAtLogin(_ enabled: Bool) async throws
}

@MainActor
@Observable
public final class AppModel {
    private let runtime: any BuildBeaconRuntime
    /// Startup belongs to the application model, rather than to any transient SwiftUI view.
    /// A menu-bar window can disappear while the user opens Settings, so a view-owned
    /// `.task` is not a reliable owner for loading the account and its workspaces.
    private var startupTask: Task<Void, Never>?
    private var didLoadConfiguration = false
    private var didStartMonitoring = false
    private var loadedWorkspaceAccountID: AccountID?
    /// The first complete snapshot establishes the comparison point. Existing pipeline
    /// state must never appear as a new event simply because the app was launched.
    private var hasReceivedMonitoringSnapshot = false
    /// Snapshot delivery can be bursty (wake/network recovery), while configuration
    /// persistence is asynchronous. A monotonic generation and serial task chain keep
    /// only the newest marker set durable and prevent an older write from winning.
    private var activityPersistenceGeneration = 0
    private var activityPersistenceTask: Task<Void, Never>?

    public var configuration = AppConfiguration()
    public var snapshot: MonitoringSnapshot?
    public var isRefreshing = false
    public var isBusy = false
    public var isMutatingMonitors = false
    public var errorMessage: String?
    public var notificationPermissionStatus: NotificationPermissionStatus?

    public var email = ""
    public var token = ""
    public var workspaces: [WorkspaceInfo] = []
    public var repositories: [RepositoryInfo] = []
    public var branches: [BranchInfo] = []
    public var selectedWorkspace: WorkspaceInfo?
    public var selectedRepository: RepositoryInfo?
    public var selectedTarget: MonitorTarget = .repositoryLatest
    public var selectedMonitorID: MonitorID?
    public var selectedPipelineRunID: PipelineRunID?
    public var selectedBuildNumber: Int?
    public var selectedHistory: [PipelineHistoryEntry] = []
    public private(set) var notificationRoute: NotificationRoute?

    public var refreshIntervalSeconds = 60
    public var notificationsEnabled = true
    public var notifyOnFailure = true
    public var notifyOnRecovery = true
    public var notifyOnApproval = true
    public var notifyOnFavoriteSuccess = false
    public var launchAtLogin = false
    public var monitorPresentation = MonitorPresentationPreferences()
    public var historyEnabled = true

    public init(runtime: any BuildBeaconRuntime) {
        self.runtime = runtime
    }

    public var isConnected: Bool { configuration.account != nil }
    /// The badge must agree with the Recent filter. Persisted markers whose run is
    /// no longer the observation currently displayed are intentionally not counted.
    public var unseenActivityCount: Int {
        snapshot?.observations.values.filter { isActivityUnseen($0) }.count ?? 0
    }

    public func isActivityUnseen(_ observation: MonitorObservation) -> Bool {
        guard let runID = observation.lastKnownRun?.id else { return false }
        return configuration.unseenActivity.contains {
            $0.monitorID == observation.monitor.id && $0.runID == runID
        }
    }

    public var aggregateState: AggregateState {
        snapshot?.aggregateState ?? (isConnected ? .configuredWithoutMonitors : .notConnected)
    }

    public var freshnessText: String {
        guard let snapshot else { return "Never updated" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let observations = Array(snapshot.observations.values)
        let needsReliableTimestamp = snapshot.aggregateState == .stale
            || snapshot.aggregateState == .unavailable
            || observations.contains(where: { $0.currentFailure != nil })
        if needsReliableTimestamp {
            guard let date = observations.compactMap(\.lastSuccessfulObservationAt).min() else {
                return "No successful update"
            }
            return "Last successful update \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "Updated \(formatter.localizedString(for: snapshot.completedAt, relativeTo: Date()))"
    }

    public var sortedObservations: [MonitorObservation] {
        guard let values = snapshot?.observations.values else { return [] }
        return values.sorted { lhs, rhs in
            let leftRank = Self.rank(lhs)
            let rightRank = Self.rank(rhs)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.monitor.projectName != rhs.monitor.projectName {
                return (lhs.monitor.projectName ?? "") < (rhs.monitor.projectName ?? "")
            }
            return lhs.monitor.repositoryName.localizedStandardCompare(rhs.monitor.repositoryName) == .orderedAscending
        }
    }

    public var selectedObservation: MonitorObservation? {
        guard let selectedMonitorID else { return nil }
        return snapshot?.observations[selectedMonitorID]
    }

    /// Starts application services without tying their lifetime to a SwiftUI view.
    /// Repeated calls coalesce into the same owned task.
    public func startIfNeeded() {
        guard startupTask == nil, startupNeedsWork else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartup()
        }
        startupTask = task
    }

    /// Waits for startup completion. Kept as the async API for callers and tests that
    /// need deterministic completion; cancelling this caller does not cancel startup.
    public func start() async {
        startIfNeeded()
        await startupTask?.value
    }

    private var startupNeedsWork: Bool {
        guard didLoadConfiguration else { return true }
        guard didStartMonitoring else { return true }
        guard let account = configuration.account else { return false }
        return loadedWorkspaceAccountID != account.id
    }

    private func performStartup() async {
        defer { startupTask = nil }

        if !didLoadConfiguration {
            do {
                apply(configuration: try await runtime.loadConfiguration())
                launchAtLogin = runtime.launchAtLoginEnabled()
                didLoadConfiguration = true
            } catch {
                errorMessage = Self.message(for: error)
                return
            }
        }

        if !didStartMonitoring {
            await runtime.startMonitoring { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot: snapshot) }
            }
            didStartMonitoring = true
        }

        guard let account = configuration.account,
              loadedWorkspaceAccountID != account.id else { return }
        do {
            let loaded = try await runtime.listWorkspaces(accountID: account.id)
            guard configuration.account?.id == account.id else { return }
            workspaces = loaded
            loadedWorkspaceAccountID = account.id
        } catch {
            guard configuration.account?.id == account.id else { return }
            errorMessage = Self.message(for: error)
        }
    }

    @discardableResult
    public func connect() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedToken = token
        defer {
            token = ""
            isBusy = false
        }
        do {
            let updated = try await runtime.connect(email: submittedEmail, token: submittedToken)
            apply(configuration: updated)
            if let account = updated.account {
                do {
                    workspaces = try await runtime.listWorkspaces(accountID: account.id)
                    loadedWorkspaceAccountID = account.id
                } catch {
                    errorMessage = Self.message(for: error)
                }
            }
            if let refreshed = await runtime.refresh(reason: .manual) {
                apply(snapshot: refreshed)
            }
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    public func revalidate() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(configuration: try await runtime.revalidate())
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(configuration: try await runtime.disconnect())
            snapshot = nil
            workspaces = []
            repositories = []
            branches = []
            selectedWorkspace = nil
            selectedRepository = nil
            selectedMonitorID = nil
            loadedWorkspaceAccountID = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func refresh(reason: RefreshReason = .manual) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let newSnapshot = await runtime.refresh(reason: reason) {
            apply(snapshot: newSnapshot)
        }
    }

    /// Refreshes only when the app becomes active after the next scheduled deadline.
    /// The monitoring engine coalesces this request with an in-flight or scheduled cycle.
    public func refreshIfDueAfterActivation(now: Date = .now) async {
        guard isConnected,
              !configuration.monitors.isEmpty,
              !isRefreshing else { return }
        guard snapshot == nil || snapshot?.nextRefreshAt.map({ $0 <= now }) == true else { return }
        await refresh(reason: .activation)
    }

    public func selectWorkspace(_ workspace: WorkspaceInfo?) async {
        selectedRepository = nil
        repositories = []
        branches = []
        guard let workspace, let account = configuration.account else { return }
        do {
            let loaded = try await runtime.listRepositories(workspace: workspace, accountID: account.id)
            guard selectedWorkspace?.id == workspace.id,
                  configuration.account?.id == account.id else { return }
            repositories = loaded
        } catch {
            guard selectedWorkspace?.id == workspace.id else { return }
            errorMessage = Self.message(for: error)
        }
    }

    public func selectRepository(_ repository: RepositoryInfo?) async {
        branches = []
        selectedTarget = .repositoryLatest
        guard let repository, let account = configuration.account else { return }
        do {
            let loaded = try await runtime.listBranches(repository: repository, accountID: account.id)
            guard selectedRepository?.id == repository.id,
                  configuration.account?.id == account.id else { return }
            branches = loaded
        } catch {
            guard selectedRepository?.id == repository.id else { return }
            errorMessage = Self.message(for: error)
        }
    }

    public func addSelectedMonitor() async {
        guard let repository = selectedRepository else { return }
        let added = await addMonitors(repositories: [repository], target: selectedTarget)
        if added == 0,
           let account = configuration.account,
           let workspace = selectedWorkspace,
           repository.workspaceID == workspace.id {
            let id = MonitorID(
                accountID: account.id,
                workspaceID: workspace.id,
                repositoryID: repository.id,
                target: selectedTarget
            )
            if configuration.monitors.contains(where: { $0.id == id }) {
                errorMessage = "This repository target is already monitored."
            }
        }
    }

    /// Persists an entire selection in one transaction so bulk selection never leaves
    /// the visible configuration partially updated.
    @discardableResult
    public func addMonitors(
        repositories: [RepositoryInfo],
        target: MonitorTarget
    ) async -> Int {
        guard !isMutatingMonitors,
              let account = configuration.account,
              let workspace = selectedWorkspace else { return 0 }

        var seenRepositoryIDs = Set<RepositoryID>()
        let uniqueRepositories = repositories.filter {
            guard $0.workspaceID == workspace.id else { return false }
            return seenRepositoryIDs.insert($0.id).inserted
        }
        guard !uniqueRepositories.isEmpty else { return 0 }

        let existingIDs = Set(configuration.monitors.map(\.id))
        let newMonitors = uniqueRepositories.compactMap { repository -> MonitorConfiguration? in
            let id = MonitorID(
                accountID: account.id,
                workspaceID: workspace.id,
                repositoryID: repository.id,
                target: target
            )
            guard !existingIDs.contains(id) else { return nil }
            return MonitorConfiguration(
                id: id,
                workspaceSlug: workspace.slug,
                workspaceName: workspace.name,
                repositorySlug: repository.slug,
                repositoryName: repository.name,
                projectName: repository.projectName
            )
        }
        guard !newMonitors.isEmpty else { return 0 }

        let wasFirstMonitorConfiguration = configuration.monitors.isEmpty
        isMutatingMonitors = true
        defer { isMutatingMonitors = false }
        do {
            let updated = try await runtime.setMonitors(configuration.monitors + newMonitors)
            apply(configuration: updated)
            if wasFirstMonitorConfiguration {
                await requestNotificationPermissionAfterFirstMonitorIfNeeded()
            }
            await refresh()
            return newMonitors.count
        } catch {
            errorMessage = Self.message(for: error)
            return 0
        }
    }

    public func removeMonitor(_ id: MonitorID) async {
        guard !isMutatingMonitors else { return }
        isMutatingMonitors = true
        defer { isMutatingMonitors = false }
        let monitors = configuration.monitors.filter { $0.id != id }
        do {
            apply(configuration: try await runtime.setMonitors(monitors))
            if selectedMonitorID == id { selectedMonitorID = nil }
            await refresh()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func toggleFavorite(for id: MonitorID) async {
        guard !isMutatingMonitors,
              let index = configuration.monitors.firstIndex(where: { $0.id == id }) else { return }
        let previous = configuration
        var updated = configuration
        updated.monitors[index].isPinned.toggle()
        isMutatingMonitors = true
        defer { isMutatingMonitors = false }
        do {
            apply(configuration: try await runtime.saveConfiguration(updated))
        } catch {
            apply(configuration: previous)
            errorMessage = Self.message(for: error)
        }
    }

    public func setRefreshInterval(_ seconds: Int) async {
        refreshIntervalSeconds = max(30, min(3_600, seconds))
        await savePreferences()
    }

    public func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        await savePreferences()
    }

    public func saveMonitorPresentation(_ preferences: MonitorPresentationPreferences) async {
        monitorPresentation = preferences
        await savePreferences()
    }

    public func setHistoryEnabled(_ enabled: Bool) async {
        historyEnabled = enabled
        await savePreferences()
    }

    public func saveNotificationPreferences() async {
        configuration.notifyOnFailure = notifyOnFailure
        configuration.notifyOnRecovery = notifyOnRecovery
        configuration.notifyOnApproval = notifyOnApproval
        configuration.notifyOnFavoriteSuccess = notifyOnFavoriteSuccess
        await savePreferences()
    }

    public func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            try await runtime.setLaunchAtLogin(enabled)
            launchAtLogin = runtime.launchAtLoginEnabled()
        } catch {
            launchAtLogin = runtime.launchAtLoginEnabled()
            errorMessage = Self.message(for: error)
        }
    }

    public func openPipelineURL(_ observation: MonitorObservation) {
        do {
            try runtime.openPipeline(observation)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func openPipelineBuildURL(monitor: MonitorConfiguration, buildNumber: Int) {
        do {
            try runtime.openPipeline(monitor: monitor, buildNumber: buildNumber)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func openPipelineBuildURL(_ observation: MonitorObservation) {
        guard let buildNumber = selectedNotificationBuildNumber ?? observation.lastKnownRun?.buildNumber else { return }
        openPipelineBuildURL(monitor: observation.monitor, buildNumber: buildNumber)
    }

    public func openCommitURL(_ run: PipelineRun) {
        guard let url = run.commitContext?.webURL else { return }
        openBitbucketURL(url)
    }

    public func openPullRequestURL(_ context: PipelinePullRequestContext) {
        guard let url = context.webURL else { return }
        openBitbucketURL(url)
    }

    private func openBitbucketURL(_ url: URL) {
        do {
            try runtime.openBitbucketURL(url)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    @discardableResult
    public func refreshNotificationPermissionStatus() async -> NotificationPermissionStatus? {
        do {
            let status = try await runtime.notificationPermissionStatus()
            notificationPermissionStatus = status
            return status
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    public func requestNotificationPermission() async -> NotificationPermissionStatus? {
        do {
            let status = try await runtime.requestNotificationPermission()
            notificationPermissionStatus = status
            return status
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    public func sendTestNotification(route: NotificationRoute) async {
        do {
            try await runtime.sendTestNotification(route: route)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func openNotificationSettings() {
        do {
            try runtime.openNotificationSettings()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func requestNotificationPermissionAfterFirstMonitorIfNeeded() async {
        guard notificationsEnabled else { return }
        let status: NotificationPermissionStatus?
        if let notificationPermissionStatus {
            status = notificationPermissionStatus
        } else {
            status = await refreshNotificationPermissionStatus()
        }
        guard status?.authorization == .notDetermined else { return }

        let requested = await requestNotificationPermission()
        switch requested?.authorization {
        case .denied:
            errorMessage = "Notifications are off. Enable them in System Settings to receive pipeline alerts."
        case nil:
            errorMessage = "Notifications could not be enabled. You can enable them later in System Settings."
        default:
            break
        }
    }

    @discardableResult
    public func loadHistory(for monitorID: MonitorID? = nil) async -> [PipelineHistoryEntry] {
        guard historyEnabled,
              let monitorID = monitorID ?? selectedMonitorID else {
            selectedHistory = []
            return []
        }
        do {
            let entries: [PipelineHistoryEntry] = try await runtime.history(for: monitorID)
            let history = entries.sorted { (lhs: PipelineHistoryEntry, rhs: PipelineHistoryEntry) in
                lhs.observedAt > rhs.observedAt
            }
            guard selectedMonitorID == monitorID else { return history }
            selectedHistory = history
            return history
        } catch {
            errorMessage = Self.message(for: error)
            return []
        }
    }

    public func clearHistory(for monitorID: MonitorID? = nil) async {
        guard let monitorID = monitorID ?? selectedMonitorID else { return }
        do {
            try await runtime.clearHistory(for: monitorID)
            if selectedMonitorID == monitorID { selectedHistory = [] }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Selects a monitor and acknowledges the latest activity attached to it. Keeping
    /// acknowledgement here makes menu-bar and dashboard interactions behave alike.
    public func selectMonitor(_ monitorID: MonitorID?) async {
        selectedMonitorID = monitorID
        guard let monitorID else { return }
        await markActivitySeen(for: monitorID)
    }

    /// Removes the single activity marker associated with a monitor. A marker records
    /// the newest run only, so opening a monitor acknowledges the visible event without
    /// retaining a growing local event log.
    public func markActivitySeen(for monitorID: MonitorID) async {
        let updatedMarkers = configuration.unseenActivity.filter { $0.monitorID != monitorID }
        stageUnseenActivity(updatedMarkers)
        await activityPersistenceTask?.value
    }

    public func markActivitySeen(for observation: MonitorObservation) async {
        await markActivitySeen(for: observation.monitor.id)
    }

    /// Selects the exact pipeline referenced by a notification instead of silently
    /// redirecting the user to a newer run received by a later polling snapshot.
    public func handleNotificationRoute(_ route: NotificationRoute) {
        guard configuration.monitors.contains(where: { $0.id == route.monitorID }) else { return }
        notificationRoute = route
        selectedMonitorID = route.monitorID
        selectedPipelineRunID = route.runID
        selectedBuildNumber = route.buildNumber
        Task { @MainActor [weak self] in
            await self?.markActivitySeen(for: route.monitorID)
        }
    }

    public var selectedNotificationBuildNumber: Int? {
        guard notificationRoute?.monitorID == selectedMonitorID else { return nil }
        return notificationRoute?.buildNumber
    }

    private func savePreferences() async {
        let previous = configuration
        configuration.refreshIntervalSeconds = refreshIntervalSeconds
        configuration.notificationsEnabled = notificationsEnabled
        configuration.notifyOnFailure = notifyOnFailure
        configuration.notifyOnRecovery = notifyOnRecovery
        configuration.notifyOnApproval = notifyOnApproval
        configuration.notifyOnFavoriteSuccess = notifyOnFavoriteSuccess
        configuration.monitorPresentation = monitorPresentation
        configuration.historyEnabled = historyEnabled
        do {
            apply(configuration: try await runtime.saveConfiguration(configuration))
        } catch {
            apply(configuration: previous)
            errorMessage = Self.message(for: error)
        }
    }

    private func apply(configuration: AppConfiguration) {
        if self.configuration.account?.id != configuration.account?.id {
            resetActivityBaselineForAccountChange()
        }
        self.configuration = configuration
        email = configuration.account?.email ?? email
        refreshIntervalSeconds = configuration.refreshIntervalSeconds
        notificationsEnabled = configuration.notificationsEnabled
        notifyOnFailure = configuration.notifyOnFailure
        notifyOnRecovery = configuration.notifyOnRecovery
        notifyOnApproval = configuration.notifyOnApproval
        notifyOnFavoriteSuccess = configuration.notifyOnFavoriteSuccess
        monitorPresentation = configuration.monitorPresentation
        historyEnabled = configuration.historyEnabled
    }

    private func apply(snapshot: MonitoringSnapshot) {
        let existingMonitorIDs = Set(configuration.monitors.map(\.id))
        var markerByMonitorID: [MonitorID: MonitorActivityMarker] = [:]
        for marker in configuration.unseenActivity where existingMonitorIDs.contains(marker.monitorID) {
            markerByMonitorID[marker.monitorID] = marker
        }

        for (monitorID, observation) in snapshot.observations {
            guard existingMonitorIDs.contains(monitorID) else { continue }
            if let currentRunID = observation.lastKnownRun?.id,
               markerByMonitorID[monitorID]?.runID != currentRunID {
                markerByMonitorID[monitorID] = nil
            }
        }

        if hasReceivedMonitoringSnapshot {
            for (monitorID, observation) in snapshot.observations {
                guard existingMonitorIDs.contains(monitorID) else { continue }
                // A monitor can be added while the app is already running. Its first
                // observation is still a baseline, not a user-unseen event.
                guard self.snapshot?.observations[monitorID] != nil else { continue }
                guard let newRunID = observation.lastKnownRun?.id else { continue }
                let oldRunID = self.snapshot?.observations[monitorID]?.lastKnownRun?.id
                guard oldRunID != newRunID else { continue }
                markerByMonitorID[monitorID] = MonitorActivityMarker(
                    monitorID: monitorID,
                    runID: newRunID
                )
            }
        }

        self.snapshot = snapshot
        hasReceivedMonitoringSnapshot = true
        if selectedMonitorID == nil {
            selectedMonitorID = Self.preferredObservation(in: snapshot)?.monitor.id
        }
        stageUnseenActivity(Array(markerByMonitorID.values))
    }

    /// Applies a canonical marker set optimistically, then saves it in an ordered
    /// background chain. On a terminal failure the exact prior configuration is
    /// restored; a newer change is never rolled back by an older request.
    private func stageUnseenActivity(_ markers: [MonitorActivityMarker]) {
        let validMonitorIDs = Set(configuration.monitors.map(\.id))
        var canonical: [MonitorActivityMarker] = []
        for marker in markers where validMonitorIDs.contains(marker.monitorID) {
            if let existingIndex = canonical.firstIndex(where: { $0.monitorID == marker.monitorID }) {
                canonical[existingIndex] = marker
            } else {
                canonical.append(marker)
            }
        }
        guard canonical != configuration.unseenActivity else { return }

        guard let accountID = configuration.account?.id else {
            configuration.unseenActivity = canonical
            return
        }
        let previousMarkers = configuration.unseenActivity
        configuration.unseenActivity = canonical
        activityPersistenceGeneration += 1
        let generation = activityPersistenceGeneration
        let predecessor = activityPersistenceTask
        activityPersistenceTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            do {
                let persisted = try await self.runtime.saveUnseenActivity(canonical, for: accountID)
                guard self.activityPersistenceGeneration == generation,
                      self.configuration.account?.id == accountID,
                      self.configuration.unseenActivity == canonical else { return }
                self.apply(configuration: persisted)
            } catch {
                guard self.activityPersistenceGeneration == generation,
                      self.configuration.account?.id == accountID,
                      self.configuration.unseenActivity == canonical else { return }
                self.configuration.unseenActivity = previousMarkers
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    /// Account identifiers scope both snapshots and persisted markers. Do not compare
    /// an incoming account against a previous account's last run, even transiently.
    private func resetActivityBaselineForAccountChange() {
        hasReceivedMonitoringSnapshot = false
        snapshot = nil
        activityPersistenceGeneration += 1
        activityPersistenceTask?.cancel()
        activityPersistenceTask = nil
    }

    private static func preferredObservation(in snapshot: MonitoringSnapshot) -> MonitorObservation? {
        snapshot.observations.values.min { rank($0) < rank($1) }
    }

    private static func rank(_ observation: MonitorObservation) -> Int {
        if observation.currentFailure != nil { return 0 }
        return switch observation.lastKnownRun?.phase {
        case .failed?, .errored?, .expired?: 0
        case .awaitingApproval?: 1
        case .running?, .queued?: 2
        case .succeeded?: 3
        case .stopped?, .unknown?, nil: 4
        }
    }

    private static func message(for error: Error) -> String {
        if let provider = error as? any ObservationFailureProviding {
            return message(for: provider.observationFailure)
        }
        if let failure = error as? ObservationFailure {
            return switch failure {
            case .invalidCredentials: "Bitbucket could not authenticate this token. In Atlassian, choose Create API token with scopes, select Bitbucket, and use your Atlassian account email."
            case .insufficientPermissions: "The token is valid but is missing a required Read permission. Create a Bitbucket API token with scopes and enable all four permissions shown above."
            case let .rateLimited(retryAt): retryAt.map { "Bitbucket rate limit reached until \($0.formatted())." } ?? "Bitbucket rate limit reached."
            case .offline: "The Mac appears to be offline."
            case .timedOut: "Bitbucket did not respond in time."
            case .notFound: "The requested Bitbucket resource was not found."
            case .malformedResponse: "Bitbucket returned a response this version cannot read."
            case let .server(status): "Bitbucket is temporarily unavailable (HTTP \(status)). Try again shortly."
            case .keychain: "The credential could not be accessed in Keychain."
            case .persistence: "The local configuration could not be saved."
            case .cancelled: "The operation was cancelled."
            case .unexpected: "An unexpected error occurred."
            }
        }
        if let accountFailure = error as? AccountManagementError {
            return switch accountFailure {
            case .invalidCredential: "Enter a valid Atlassian email and API token."
            case .noConnectedAccount: "No Bitbucket account is connected."
            case .monitorBelongsToAnotherAccount: "This monitor belongs to a different Bitbucket account."
            case .rollbackFailed: "The account change could not be completed safely. Your previous configuration was preserved where possible."
            }
        }
        return error.localizedDescription
    }
}
