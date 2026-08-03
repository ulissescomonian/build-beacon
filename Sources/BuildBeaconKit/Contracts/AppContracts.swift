import Foundation

public struct AccountID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WorkspaceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct RepositoryID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PipelineRunID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PipelineStepID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MonitorTarget: Hashable, Codable, Sendable {
    case repositoryLatest
    case defaultBranch
    case branch(exactName: String)

    public var displayName: String {
        switch self {
        case .repositoryLatest: "Latest run"
        case .defaultBranch: "Default branch"
        case let .branch(name): name
        }
    }
}

public struct MonitorID: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public let workspaceID: WorkspaceID
    public let repositoryID: RepositoryID
    public let target: MonitorTarget

    public init(
        accountID: AccountID,
        workspaceID: WorkspaceID,
        repositoryID: RepositoryID,
        target: MonitorTarget
    ) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.repositoryID = repositoryID
        self.target = target
    }
}

/// Identifies a pipeline run whose activity has not yet been acknowledged in
/// the dashboard. It intentionally stores only stable opaque identifiers.
public struct MonitorActivityMarker: Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID

    public init(monitorID: MonitorID, runID: PipelineRunID) {
        self.monitorID = monitorID
        self.runID = runID
    }
}

/// The stable, opaque identity of one pipeline approval wait.
public struct ApprovalReminderIdentity: Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID

    public init(monitorID: MonitorID, runID: PipelineRunID) {
        self.monitorID = monitorID
        self.runID = runID
    }
}

/// A locally observed approval wait. It contains no author, branch, commit, or
/// pipeline payload, only the identifiers required to route a reminder.
public struct ApprovalWaitMarker: Hashable, Codable, Sendable {
    public let identity: ApprovalReminderIdentity
    public let firstDetectedAt: Date

    public var monitorID: MonitorID { identity.monitorID }
    public var runID: PipelineRunID { identity.runID }

    public init(
        monitorID: MonitorID,
        runID: PipelineRunID,
        firstDetectedAt: Date
    ) {
        self.identity = ApprovalReminderIdentity(monitorID: monitorID, runID: runID)
        self.firstDetectedAt = firstDetectedAt
    }
}

public enum ApprovalReminderInterval: String, Hashable, Codable, Sendable, CaseIterable {
    case none
    case tenMinutes
    case fifteenMinutes

    public var duration: TimeInterval? {
        switch self {
        case .none: nil
        case .tenMinutes: 10 * 60
        case .fifteenMinutes: 15 * 60
        }
    }
}

public enum PipelinePhase: Hashable, Codable, Sendable {
    case queued
    case running
    case awaitingApproval
    case succeeded
    case failed
    case errored
    case expired
    case stopped
    case unknown(remoteState: String?, remoteResult: String?)
}

public enum PipelineStepPhase: Hashable, Codable, Sendable {
    case queued
    case running
    case awaitingApproval
    case succeeded
    case failed
    case stopped
    case unknown
}

public struct PipelineStep: Identifiable, Hashable, Codable, Sendable {
    public let id: PipelineStepID
    public let name: String
    public let phase: PipelineStepPhase
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        id: PipelineStepID,
        name: String,
        phase: PipelineStepPhase,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Describes the Bitbucket target that caused a pipeline to run.
///
/// This is deliberately independent from optional pull request enrichment: a
/// pipeline target can identify a pull request even when its details cannot be
/// loaded.
public enum PipelineRunOrigin: Hashable, Codable, Sendable {
    case branch(name: String?)
    case pullRequest(id: Int?, sourceBranch: String?, destinationBranch: String?)
    case unknown
}

public struct PipelineRun: Identifiable, Hashable, Codable, Sendable {
    public let id: PipelineRunID
    public let buildNumber: Int
    public let phase: PipelinePhase
    public let branchName: String?
    public let origin: PipelineRunOrigin
    public let commitHash: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let failureReason: String?
    public let steps: [PipelineStep]
    public let commitContext: PipelineCommitContext?
    public let pullRequest: PipelinePullRequestContext?

    public init(
        id: PipelineRunID,
        buildNumber: Int,
        phase: PipelinePhase,
        branchName: String? = nil,
        origin: PipelineRunOrigin = .unknown,
        commitHash: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        failureReason: String? = nil,
        steps: [PipelineStep] = [],
        commitContext: PipelineCommitContext? = nil,
        pullRequest: PipelinePullRequestContext? = nil
    ) {
        self.id = id
        self.buildNumber = buildNumber
        self.phase = phase
        self.branchName = branchName
        self.origin = origin
        self.commitHash = commitHash
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failureReason = failureReason
        self.steps = steps
        self.commitContext = commitContext
        self.pullRequest = pullRequest
    }

    private enum CodingKeys: String, CodingKey {
        case id, buildNumber, phase, branchName, origin, commitHash, startedAt, completedAt
        case failureReason, steps, commitContext, pullRequest
    }

    /// Older local history records predate `origin`; retain them as unknown
    /// rather than making a harmless UI upgrade discard user history.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PipelineRunID.self, forKey: .id)
        buildNumber = try container.decode(Int.self, forKey: .buildNumber)
        phase = try container.decode(PipelinePhase.self, forKey: .phase)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        origin = try container.decodeIfPresent(PipelineRunOrigin.self, forKey: .origin) ?? .unknown
        commitHash = try container.decodeIfPresent(String.self, forKey: .commitHash)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        steps = try container.decodeIfPresent([PipelineStep].self, forKey: .steps) ?? []
        commitContext = try container.decodeIfPresent(PipelineCommitContext.self, forKey: .commitContext)
        pullRequest = try container.decodeIfPresent(PipelinePullRequestContext.self, forKey: .pullRequest)
    }
}

public struct PipelineCommitContext: Hashable, Codable, Sendable {
    public let message: String?
    public let authorName: String?
    public let date: Date?
    public let webURL: URL?

    public init(message: String? = nil, authorName: String? = nil, date: Date? = nil, webURL: URL? = nil) {
        self.message = message
        self.authorName = authorName
        self.date = date
        self.webURL = webURL
    }
}

public struct PipelinePullRequestContext: Hashable, Codable, Sendable {
    public let id: Int
    public let title: String
    public let state: String
    public let authorName: String?
    public let webURL: URL?

    public init(
        id: Int,
        title: String,
        state: String,
        authorName: String? = nil,
        webURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.authorName = authorName
        self.webURL = webURL
    }
}

public struct WorkspaceInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: WorkspaceID
    public let slug: String
    public let name: String

    public init(id: WorkspaceID, slug: String, name: String) {
        self.id = id
        self.slug = slug
        self.name = name
    }
}

public struct RepositoryInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: RepositoryID
    public let workspaceID: WorkspaceID
    public let workspaceSlug: String
    public let slug: String
    public let name: String
    public let projectKey: String?
    public let projectName: String?
    public let defaultBranch: String?

    public init(
        id: RepositoryID,
        workspaceID: WorkspaceID,
        workspaceSlug: String,
        slug: String,
        name: String,
        projectKey: String? = nil,
        projectName: String? = nil,
        defaultBranch: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceSlug = workspaceSlug
        self.slug = slug
        self.name = name
        self.projectKey = projectKey
        self.projectName = projectName
        self.defaultBranch = defaultBranch
    }
}

public struct BranchInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let isDefault: Bool

    public init(name: String, isDefault: Bool = false) {
        self.name = name
        self.isDefault = isDefault
    }
}

public struct MonitorConfiguration: Identifiable, Hashable, Codable, Sendable {
    public let id: MonitorID
    public var workspaceSlug: String
    public var workspaceName: String
    public var repositorySlug: String
    public var repositoryName: String
    public var projectName: String?
    public var isPinned: Bool
    public var isHidden: Bool
    /// Production is an explicit monitor decision. Branch names are deliberately
    /// not inferred because main/master are not universally production targets.
    public var isProduction: Bool

    /// The persisted `isPinned` key predates the user-facing favorite control.
    /// Keep it as the storage-compatible source of truth.
    public var isFavorite: Bool {
        get { isPinned }
        set { isPinned = newValue }
    }

    public init(
        id: MonitorID,
        workspaceSlug: String,
        workspaceName: String,
        repositorySlug: String,
        repositoryName: String,
        projectName: String? = nil,
        isPinned: Bool = false,
        isHidden: Bool = false,
        isProduction: Bool = false
    ) {
        self.id = id
        self.workspaceSlug = workspaceSlug
        self.workspaceName = workspaceName
        self.repositorySlug = repositorySlug
        self.repositoryName = repositoryName
        self.projectName = projectName
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.isProduction = isProduction
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceSlug, workspaceName, repositorySlug, repositoryName, projectName, isPinned, isHidden, isProduction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(MonitorID.self, forKey: .id)
        workspaceSlug = try values.decode(String.self, forKey: .workspaceSlug)
        workspaceName = try values.decode(String.self, forKey: .workspaceName)
        repositorySlug = try values.decode(String.self, forKey: .repositorySlug)
        repositoryName = try values.decode(String.self, forKey: .repositoryName)
        projectName = try values.decodeIfPresent(String.self, forKey: .projectName)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isProduction = try values.decodeIfPresent(Bool.self, forKey: .isProduction) ?? false
    }
}

public enum ObservationFailure: Error, Hashable, Codable, Sendable {
    case invalidCredentials
    case insufficientPermissions
    case rateLimited(retryAt: Date?)
    case offline
    case timedOut
    case notFound
    case malformedResponse
    case server(status: Int)
    case keychain
    case persistence
    case cancelled
    case unexpected
}

/// Allows infrastructure adapters to expose a stable domain failure without
/// coupling the monitoring engine to a concrete API implementation.
public protocol ObservationFailureProviding: Error, Sendable {
    var observationFailure: ObservationFailure { get }
}

public struct MonitorObservation: Hashable, Codable, Sendable {
    public let monitor: MonitorConfiguration
    public var lastKnownRun: PipelineRun?
    public var attemptedAt: Date?
    public var lastSuccessfulObservationAt: Date?
    public var currentFailure: ObservationFailure?

    public init(
        monitor: MonitorConfiguration,
        lastKnownRun: PipelineRun? = nil,
        attemptedAt: Date? = nil,
        lastSuccessfulObservationAt: Date? = nil,
        currentFailure: ObservationFailure? = nil
    ) {
        self.monitor = monitor
        self.lastKnownRun = lastKnownRun
        self.attemptedAt = attemptedAt
        self.lastSuccessfulObservationAt = lastSuccessfulObservationAt
        self.currentFailure = currentFailure
    }
}

public enum AggregateState: String, Hashable, Codable, Sendable {
    case attentionRequired
    case unavailable
    case stale
    case awaitingApproval
    case running
    case healthy
    case configuredWithoutMonitors
    case notConnected
}

public enum RefreshReason: String, Hashable, Codable, Sendable {
    case startup
    case scheduled
    case manual
    case retry
    case wake
    case configurationChanged
    case activation
    case networkRecovery
}

public struct MonitoringSnapshot: Hashable, Codable, Sendable {
    public let cycleID: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let reason: RefreshReason
    public let observations: [MonitorID: MonitorObservation]
    public let aggregateState: AggregateState
    public let nextRefreshAt: Date?
    public let isComplete: Bool

    public init(
        cycleID: UUID,
        startedAt: Date,
        completedAt: Date,
        reason: RefreshReason,
        observations: [MonitorID: MonitorObservation],
        aggregateState: AggregateState,
        nextRefreshAt: Date? = nil,
        isComplete: Bool = true
    ) {
        self.cycleID = cycleID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.reason = reason
        self.observations = observations
        self.aggregateState = aggregateState
        self.nextRefreshAt = nextRefreshAt
        self.isComplete = isComplete
    }
}

public struct AccountProfile: Hashable, Codable, Sendable {
    public let id: AccountID
    public let displayName: String
    public let email: String

    public init(id: AccountID, displayName: String, email: String) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }
}

public struct AccountCredential: Sendable, CustomStringConvertible {
    public let email: String
    public let token: String

    public init(email: String, token: String) {
        self.email = email
        self.token = token
    }

    public var description: String { "AccountCredential(email: <private>, token: <redacted>)" }
}

public struct AppConfiguration: Hashable, Codable, Sendable {
    public static let schemaVersion = 4

    public var account: AccountProfile?
    public var monitors: [MonitorConfiguration]
    public var refreshIntervalSeconds: Int
    public var notificationsEnabled: Bool
    public var notifyOnFailure: Bool
    public var notifyOnRecovery: Bool
    public var notifyOnApproval: Bool
    public var notifyOnFavoriteSuccess: Bool
    public var monitorPresentation: MonitorPresentationPreferences
    public var historyEnabled: Bool
    public var unseenActivity: [MonitorActivityMarker]
    public var approvalWaits: [ApprovalWaitMarker]
    public var approvalReminderInterval: ApprovalReminderInterval

    public init(
        account: AccountProfile? = nil,
        monitors: [MonitorConfiguration] = [],
        refreshIntervalSeconds: Int = 60,
        notificationsEnabled: Bool = true,
        notifyOnFailure: Bool = true,
        notifyOnRecovery: Bool = true,
        notifyOnApproval: Bool = true,
        notifyOnFavoriteSuccess: Bool = false,
        monitorPresentation: MonitorPresentationPreferences = .init(),
        historyEnabled: Bool = true,
        unseenActivity: [MonitorActivityMarker] = [],
        approvalWaits: [ApprovalWaitMarker] = [],
        approvalReminderInterval: ApprovalReminderInterval = .none
    ) {
        self.account = account
        self.monitors = monitors
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.notificationsEnabled = notificationsEnabled
        self.notifyOnFailure = notifyOnFailure
        self.notifyOnRecovery = notifyOnRecovery
        self.notifyOnApproval = notifyOnApproval
        self.notifyOnFavoriteSuccess = notifyOnFavoriteSuccess
        self.monitorPresentation = monitorPresentation
        self.historyEnabled = historyEnabled
        self.unseenActivity = unseenActivity
        self.approvalWaits = approvalWaits
        self.approvalReminderInterval = approvalReminderInterval
    }

    private enum CodingKeys: String, CodingKey {
        case account, monitors, refreshIntervalSeconds, notificationsEnabled, notifyOnFailure, notifyOnRecovery, notifyOnApproval, notifyOnFavoriteSuccess, monitorPresentation, historyEnabled, unseenActivity, approvalWaits, approvalReminderInterval
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decodeIfPresent(AccountProfile.self, forKey: .account)
        monitors = try values.decode([MonitorConfiguration].self, forKey: .monitors)
        refreshIntervalSeconds = try values.decode(Int.self, forKey: .refreshIntervalSeconds)
        notificationsEnabled = try values.decode(Bool.self, forKey: .notificationsEnabled)
        notifyOnFailure = try values.decode(Bool.self, forKey: .notifyOnFailure)
        notifyOnRecovery = try values.decode(Bool.self, forKey: .notifyOnRecovery)
        notifyOnApproval = try values.decode(Bool.self, forKey: .notifyOnApproval)
        notifyOnFavoriteSuccess = try values.decode(Bool.self, forKey: .notifyOnFavoriteSuccess)
        monitorPresentation = try values.decode(MonitorPresentationPreferences.self, forKey: .monitorPresentation)
        historyEnabled = try values.decode(Bool.self, forKey: .historyEnabled)
        unseenActivity = try values.decode([MonitorActivityMarker].self, forKey: .unseenActivity)
        approvalWaits = try values.decodeIfPresent([ApprovalWaitMarker].self, forKey: .approvalWaits) ?? []
        approvalReminderInterval = try values.decodeIfPresent(ApprovalReminderInterval.self, forKey: .approvalReminderInterval) ?? .none
    }
}

public struct MonitorPresentationPreferences: Hashable, Codable, Sendable {
    public enum Grouping: String, Hashable, Codable, Sendable {
        case none
        case project
    }

    public enum SortOrder: String, Hashable, Codable, Sendable {
        case status
        case project
        case repository
        case recentActivity
    }

    public var grouping: Grouping
    public var sortOrder: SortOrder
    public var favoritesFirst: Bool
    public var hideRepositoriesWithoutRuns: Bool

    public init(
        grouping: Grouping = .none,
        sortOrder: SortOrder = .recentActivity,
        favoritesFirst: Bool = true,
        hideRepositoriesWithoutRuns: Bool = false
    ) {
        self.grouping = grouping
        self.sortOrder = sortOrder
        self.favoritesFirst = favoritesFirst
        self.hideRepositoriesWithoutRuns = hideRepositoriesWithoutRuns
    }
}

public struct PipelineHistoryEntry: Identifiable, Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID
    public let buildNumber: Int
    public let phase: PipelinePhase
    public let startedAt: Date?
    public let completedAt: Date?
    public let observedAt: Date

    public var id: PipelineHistoryEntryID { .init(monitorID: monitorID, runID: runID) }

    public init(
        monitorID: MonitorID,
        runID: PipelineRunID,
        buildNumber: Int,
        phase: PipelinePhase,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        observedAt: Date = .now
    ) {
        self.monitorID = monitorID
        self.runID = runID
        self.buildNumber = buildNumber
        self.phase = phase
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observedAt = observedAt
    }
}

/// A typed composite identity avoids UI diff collisions when the same pipeline
/// run is monitored through multiple targets in one repository.
public struct PipelineHistoryEntryID: Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID

    public init(monitorID: MonitorID, runID: PipelineRunID) {
        self.monitorID = monitorID
        self.runID = runID
    }
}

public protocol PipelineHistoryStore: Sendable {
    func record(observation: MonitorObservation, at date: Date) async throws
    func entries(for monitorID: MonitorID, at date: Date) async throws -> [PipelineHistoryEntry]
    func remove(for monitorID: MonitorID) async throws
    func removeAll(for accountID: AccountID) async throws
    func reset() async throws
}

public protocol CredentialStore: Sendable {
    func save(_ credential: AccountCredential, accountID: AccountID) async throws
    func load(accountID: AccountID) async throws -> AccountCredential?
    func delete(accountID: AccountID) async throws
}

public protocol ConfigurationStore: Sendable {
    func load() async throws -> AppConfiguration
    func save(_ configuration: AppConfiguration) async throws
    func saveApprovalWaits(_ markers: [ApprovalWaitMarker], for accountID: AccountID) async throws -> AppConfiguration
    func reset() async throws
}

public extension ConfigurationStore {
    /// Compatibility default for test and third-party stores that do not retain
    /// presentation-only approval timing. Production uses the specialized JSON
    /// implementation above.
    func saveApprovalWaits(
        _ markers: [ApprovalWaitMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        try await load()
    }
}

public protocol BitbucketService: Sendable {
    func validate(credential: AccountCredential) async throws -> AccountProfile
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo]
    func listRepositories(in workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo]
    func listBranches(in repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo]
    func latestPipeline(for monitor: MonitorConfiguration) async throws -> PipelineRun?
}

public enum NotificationEventKind: String, Hashable, Codable, Sendable {
    case failed
    case recovered
    case succeeded
    case awaitingApproval
    case authenticationRequired
}

public struct NotificationEvent: Hashable, Codable, Sendable {
    public let kind: NotificationEventKind
    public let monitorID: MonitorID
    public let runID: PipelineRunID?
    public let buildNumber: Int?
    public let title: String
    public let body: String

    public init(
        kind: NotificationEventKind,
        monitorID: MonitorID,
        runID: PipelineRunID?,
        buildNumber: Int? = nil,
        title: String,
        body: String
    ) {
        self.kind = kind
        self.monitorID = monitorID
        self.runID = runID
        self.buildNumber = buildNumber
        self.title = title
        self.body = body
    }
}

public enum NotificationAuthorizationState: String, Hashable, Codable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unsupported
}

public struct NotificationPermissionStatus: Hashable, Codable, Sendable {
    public let authorization: NotificationAuthorizationState
    public let alertsEnabled: Bool
    public let soundsEnabled: Bool

    public init(
        authorization: NotificationAuthorizationState,
        alertsEnabled: Bool,
        soundsEnabled: Bool
    ) {
        self.authorization = authorization
        self.alertsEnabled = alertsEnabled
        self.soundsEnabled = soundsEnabled
    }
}

public struct NotificationRoute: Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID?
    public let buildNumber: Int?

    public init(monitorID: MonitorID, runID: PipelineRunID? = nil, buildNumber: Int? = nil) {
        self.monitorID = monitorID
        self.runID = runID
        self.buildNumber = buildNumber
    }
}

public protocol NotificationSending: Sendable {
    func configureCategories() async throws
    func permissionStatus() async throws -> NotificationPermissionStatus
    func requestAuthorization() async throws -> NotificationPermissionStatus
    func deliverTest(route: NotificationRoute) async throws
    func deliver(_ event: NotificationEvent) async throws
    func removePending(for monitorID: MonitorID) async
    func reconcileApprovalReminders(
        activeApprovals: [ApprovalWaitMarker],
        interval: ApprovalReminderInterval
    ) async
}
