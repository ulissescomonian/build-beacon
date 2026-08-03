import Foundation
@preconcurrency import UserNotifications
import XCTest
@testable import BuildBeaconKit

final class InfrastructureServicesTests: XCTestCase, @unchecked Sendable {
    func testNotificationServiceUsesLedgerToDeduplicateAndRemove() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = NotificationCenterFake(status: .authorized)
        let ledger = NotificationLedger(fileURL: directory.appendingPathComponent("ledger.json"))
        let service = UserNotificationService(center: center, ledger: ledger)
        let event = notificationEvent()

        try await service.deliver(event)
        try await service.deliver(event)

        let addedCount = center.addedCount
        let recordedEntries = try await ledger.allEntries()
        XCTAssertEqual(addedCount, 1)
        XCTAssertEqual(recordedEntries.count, 1)
        await service.removePending(for: event.monitorID)
        let pendingCount = center.pendingCount
        let remainingEntries = try await ledger.allEntries()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertTrue(remainingEntries.isEmpty)
    }

    func testNotificationServiceRefusesDeliveryWithoutAuthorization() async throws {
        let center = NotificationCenterFake(status: .denied)
        let service = UserNotificationService(center: center)

        do {
            try await service.deliver(notificationEvent())
            XCTFail("Expected authorization failure")
        } catch let error as UserNotificationServiceError {
            XCTAssertEqual(error, .authorizationDenied)
        }
        let addedCount = center.addedCount
        XCTAssertEqual(addedCount, 0)
    }

    func testNotificationServiceReportsLivePermissionStatusAndRegistersCategories() async throws {
        let center = NotificationCenterFake(
            status: .notDetermined,
            alertsEnabled: false,
            soundsEnabled: false
        )
        let service = UserNotificationService(center: center)

        let initial = try await service.permissionStatus()
        XCTAssertEqual(initial.authorization, .notDetermined)
        XCTAssertFalse(initial.alertsEnabled)
        XCTAssertFalse(initial.soundsEnabled)

        try await service.configureCategories()

        XCTAssertEqual(center.categoryIdentifiers, [
            UserNotificationService.categoryIdentifier,
            UserNotificationService.approvalCategoryIdentifier,
            UserNotificationService.approvalReminderCategoryIdentifier,
        ])
        XCTAssertTrue(center.openActionUsesForegroundPresentation)
        XCTAssertTrue(center.approvalActionsAreForeground)
    }

    func testNotificationServicePreservesAuthorizationStates() async throws {
        let cases: [(UNAuthorizationStatus, NotificationAuthorizationState)] = [
            (.notDetermined, .notDetermined),
            (.authorized, .authorized),
            (.provisional, .provisional),
            (.denied, .denied)
        ]

        for (systemStatus, expectedStatus) in cases {
            let service = UserNotificationService(center: NotificationCenterFake(status: systemStatus))
            let status = try await service.permissionStatus()
            XCTAssertEqual(status.authorization, expectedStatus)
        }
    }

    func testNotificationServiceRequestsAuthorizationThenReturnsFinalStatus() async throws {
        let center = NotificationCenterFake(status: .notDetermined)
        center.status = .authorized
        let service = UserNotificationService(center: center)

        let status = try await service.requestAuthorization()

        XCTAssertEqual(status.authorization, .authorized)
        XCTAssertTrue(status.alertsEnabled)
        XCTAssertTrue(status.soundsEnabled)
        XCTAssertEqual(center.authorizationRequests, 1)
    }

    func testNotificationServiceEncodesExactRouteForEventsAndTestDelivery() async throws {
        let center = NotificationCenterFake(status: .authorized)
        let service = UserNotificationService(center: center)
        let event = notificationEvent(repository: "exact", buildNumber: 42)
        let expected = NotificationRoute(
            monitorID: event.monitorID,
            runID: event.runID,
            buildNumber: 42
        )

        try await service.deliver(event)
        try await service.deliverTest(route: expected)

        let requests = center.allRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(NotificationRoutePayload.route(from: requests[0].content.userInfo), expected)
        XCTAssertEqual(NotificationRoutePayload.route(from: requests[1].content.userInfo), expected)
        XCTAssertEqual(requests[1].content.title, "Build Beacon notifications are working")
    }

    func testApprovalEventUsesTheActionableApprovalCategory() async throws {
        let center = NotificationCenterFake(status: .authorized)
        let service = UserNotificationService(center: center)
        let event = NotificationEvent(
            kind: .awaitingApproval,
            monitorID: notificationEvent().monitorID,
            runID: PipelineRunID(rawValue: "approval-run"),
            buildNumber: 42,
            title: "Approval required",
            body: "A pipeline is waiting for approval."
        )

        try await service.deliver(event)

        XCTAssertEqual(
            center.allRequests.first?.content.categoryIdentifier,
            UserNotificationService.approvalCategoryIdentifier
        )
    }

    func testNotificationServiceRemovesOnlyTheRequestedMonitor() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = NotificationCenterFake(status: .authorized)
        let ledger = NotificationLedger(fileURL: directory.appendingPathComponent("ledger.json"))
        let service = UserNotificationService(center: center, ledger: ledger)
        let first = notificationEvent(repository: "one")
        let second = notificationEvent(repository: "two")

        try await service.deliver(first)
        try await service.deliver(second)
        await service.removePending(for: first.monitorID)

        XCTAssertEqual(center.pendingCount, 1)
        let entries = try await ledger.allEntries()
        XCTAssertEqual(entries.map(\.monitorID), [second.monitorID])
    }

    func testApprovalReminderIsScheduledOnlyOnceForTheSameWait() async throws {
        let center = NotificationCenterFake(status: .authorized)
        let service = UserNotificationService(center: center)
        let marker = approvalWaitMarker(repository: "approval", runID: "42")

        await service.reconcileApprovalReminders(
            activeApprovals: [marker],
            interval: .tenMinutes
        )
        await service.reconcileApprovalReminders(
            activeApprovals: [marker],
            interval: .tenMinutes
        )

        let requests = center.allRequests.filter {
            $0.content.categoryIdentifier == UserNotificationService.approvalReminderCategoryIdentifier
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            NotificationRoutePayload.route(from: try XCTUnwrap(requests.first).content.userInfo),
            NotificationRoute(monitorID: marker.monitorID, runID: marker.runID)
        )
        XCTAssertNotNil(requests.first?.trigger as? UNTimeIntervalNotificationTrigger)
    }

    func testApprovalReminderIsCancelledWhenWaitResolvesOrPreferenceIsDisabled() async throws {
        let center = NotificationCenterFake(status: .authorized)
        let service = UserNotificationService(center: center)
        let marker = approvalWaitMarker(repository: "approval", runID: "42")

        await service.reconcileApprovalReminders(activeApprovals: [marker], interval: .fifteenMinutes)
        await service.reconcileApprovalReminders(activeApprovals: [], interval: .fifteenMinutes)
        XCTAssertEqual(center.approvalReminderPendingCount, 0)

        await service.reconcileApprovalReminders(activeApprovals: [marker], interval: .tenMinutes)
        await service.reconcileApprovalReminders(activeApprovals: [marker], interval: .none)
        XCTAssertEqual(center.approvalReminderPendingCount, 0)
    }

    func testApprovalReminderReplacesThePendingRequestWhenIntervalChanges() async throws {
        let center = NotificationCenterFake(status: .authorized)
        let service = UserNotificationService(center: center)
        let marker = approvalWaitMarker(repository: "approval", runID: "42")

        await service.reconcileApprovalReminders(activeApprovals: [marker], interval: .tenMinutes)
        let originalIdentifier = try XCTUnwrap(center.approvalReminderIdentifiers.first)
        await service.reconcileApprovalReminders(activeApprovals: [marker], interval: .fifteenMinutes)

        XCTAssertEqual(center.approvalReminderPendingCount, 1)
        XCTAssertNotEqual(try XCTUnwrap(center.approvalReminderIdentifiers.first), originalIdentifier)
    }

    func testDeliveredApprovalReminderIsNotScheduledAgainAfterRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = NotificationLedger(fileURL: directory.appendingPathComponent("ledger.json"))
        let center = NotificationCenterFake(status: .authorized)
        let marker = approvalWaitMarker(repository: "approval", runID: "42")
        let firstService = UserNotificationService(center: center, ledger: ledger)

        await firstService.reconcileApprovalReminders(activeApprovals: [marker], interval: .tenMinutes)
        let deliveredIdentifier = try XCTUnwrap(center.approvalReminderIdentifiers.first)
        await center.removePendingRequests(withIdentifiers: [deliveredIdentifier])
        await firstService.reconcileApprovalReminders(activeApprovals: [marker], interval: .tenMinutes)
        XCTAssertEqual(center.totalAddedCount, 1)

        let relaunchedService = UserNotificationService(center: center, ledger: ledger)
        await relaunchedService.reconcileApprovalReminders(activeApprovals: [marker], interval: .tenMinutes)
        XCTAssertEqual(center.totalAddedCount, 1)
    }

    func testLedgerPersistsWithPrivateDirectoryAndFilePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("ledger.json")
        let ledger = NotificationLedger(fileURL: fileURL)

        try await ledger.record(notificationEvent())

        let directoryPermissions = try permissions(of: directory)
        let filePermissions = try permissions(of: fileURL)
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(filePermissions, 0o600)
    }

    func testLedgerPrunesExpiredAndExcessEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = NotificationLedger(
            fileURL: directory.appendingPathComponent("ledger.json"),
            retentionInterval: 100,
            maximumEntryCount: 2
        )
        let base = Date(timeIntervalSince1970: 1_000)
        try await ledger.record(notificationEvent(repository: "expired"), at: base)
        try await ledger.record(notificationEvent(repository: "one"), at: base.addingTimeInterval(101))
        try await ledger.record(notificationEvent(repository: "two"), at: base.addingTimeInterval(102))
        try await ledger.record(notificationEvent(repository: "three"), at: base.addingTimeInterval(103))

        let entries = try await ledger.allEntries(at: base.addingTimeInterval(103))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.monitorID.repositoryID.rawValue), ["two", "three"])
    }

    func testLedgerReadsVersionOnePayloadBeforeRecordingApprovalReminder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        let event = notificationEvent()
        let legacy = LegacyLedgerEnvelope(entries: [
            NotificationLedgerEntry(
                monitorID: event.monitorID,
                runID: event.runID,
                kind: event.kind,
                recordedAt: .now
            ),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: fileURL)
        let ledger = NotificationLedger(fileURL: fileURL)
        let identity = ApprovalReminderIdentity(monitorID: event.monitorID, runID: PipelineRunID(rawValue: "reminder"))

        let containsEvent = try await ledger.contains(event)
        XCTAssertTrue(containsEvent)
        try await ledger.recordApprovalReminder(identity, interval: .tenMinutes)
        let containsReminder = try await ledger.containsApprovalReminder(identity, interval: .tenMinutes)
        XCTAssertTrue(containsReminder)
    }

    func testLedgerRollsBackMemoryWhenRecordOrRemovePersistenceFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = root.appendingPathComponent("store", isDirectory: true)
        let savedContainer = root.appendingPathComponent("saved-store", isDirectory: true)
        // A regular file where the ledger expects a directory deterministically
        // makes its atomic persistence fail.
        try Data("blocked".utf8).write(to: container)
        let ledger = NotificationLedger(fileURL: container.appendingPathComponent("ledger.json"))
        let event = notificationEvent()

        do {
            try await ledger.record(event)
            XCTFail("Expected record persistence to fail")
        } catch is NotificationLedgerError { }

        try FileManager.default.removeItem(at: container)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let recordedAfterFailure = try await ledger.contains(event)
        XCTAssertFalse(recordedAfterFailure)

        try await ledger.record(event)
        try FileManager.default.moveItem(at: container, to: savedContainer)
        try Data("blocked".utf8).write(to: container)

        do {
            try await ledger.remove(for: event.monitorID)
            XCTFail("Expected remove persistence to fail")
        } catch is NotificationLedgerError { }

        try FileManager.default.removeItem(at: container)
        try FileManager.default.moveItem(at: savedContainer, to: container)
        let recordedAfterFailedRemoval = try await ledger.contains(event)
        XCTAssertTrue(recordedAfterFailedRemoval)
    }

    func testSafeLinkPolicyRejectsUnsafeURLs() throws {
        let policy = SafeLinkPolicy()
        XCTAssertNoThrow(try policy.validate(XCTUnwrap(URL(string: "https://bitbucket.org/team/repo"))))
        XCTAssertThrowsError(try policy.validate(XCTUnwrap(URL(string: "http://bitbucket.org/team/repo"))))
        XCTAssertThrowsError(try policy.validate(XCTUnwrap(URL(string: "https://evil.example/team/repo"))))
        XCTAssertThrowsError(try policy.validate(XCTUnwrap(URL(string: "https://user:pass@bitbucket.org/team/repo"))))
        XCTAssertThrowsError(try policy.validate(XCTUnwrap(URL(string: "https://bitbucket.org:8443/team/repo"))))
    }

    func testLogRedactorRemovesSecretsAndSensitiveHeaders() {
        let token = "super-secret-token"
        let message = "Authorization: Bearer \(token), token=\(token)"
        let result = LogRedactor.redact(message, secrets: [token])
        XCTAssertFalse(result.contains(token))
        XCTAssertTrue(result.contains("<redacted>"))

        let headers = LogRedactor.redact(headers: [
            "Authorization": "Bearer secret",
            "X-Api-Key": "another-secret",
            "Accept": "application/json",
        ])
        XCTAssertEqual(headers["Authorization"], "<redacted>")
        XCTAssertEqual(headers["X-Api-Key"], "<redacted>")
        XCTAssertEqual(headers["Accept"], "application/json")
    }

    func testKeychainCredentialLifecycleWhenIntegrationIsEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BUILD_BEACON_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BUILD_BEACON_KEYCHAIN_INTEGRATION=1 to exercise the real login Keychain")
        }
        let serviceName = "com.buildbeacon.tests.\(UUID().uuidString)"
        let accountID = AccountID(rawValue: UUID().uuidString)
        let store = KeychainCredentialStore(service: serviceName)
        try? await store.delete(accountID: accountID)

        try await store.save(AccountCredential(email: "person@example.com", token: "first"), accountID: accountID)
        var loaded = try await store.load(accountID: accountID)
        XCTAssertEqual(loaded?.email, "person@example.com")
        XCTAssertEqual(loaded?.token, "first")

        try await store.save(AccountCredential(email: "person@example.com", token: "second"), accountID: accountID)
        loaded = try await store.load(accountID: accountID)
        XCTAssertEqual(loaded?.token, "second")

        try await store.delete(accountID: accountID)
        let deleted = try await store.load(accountID: accountID)
        XCTAssertNil(deleted)
    }

    func testPullRequestActionKeychainUsesAnIndependentService() {
        XCTAssertEqual(
            KeychainPullRequestActionCredentialStore.defaultService,
            "com.epyczones.buildbeacon.bitbucket-pr-actions-token"
        )
        XCTAssertNotEqual(
            KeychainPullRequestActionCredentialStore.defaultService,
            "com.epyczones.buildbeacon.bitbucket-api-token"
        )
    }

    func testPullRequestActionKeychainLifecycleIsIsolatedWhenIntegrationIsEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BUILD_BEACON_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BUILD_BEACON_KEYCHAIN_INTEGRATION=1 to exercise the real login Keychain")
        }
        let suffix = UUID().uuidString
        let accountID = AccountID(rawValue: "{account}")
        let monitoringStore = KeychainCredentialStore(service: "com.buildbeacon.tests.monitoring.\(suffix)")
        let actionStore = KeychainPullRequestActionCredentialStore(
            service: "com.buildbeacon.tests.actions.\(suffix)"
        )
        try? await monitoringStore.delete(accountID: accountID)
        try? await actionStore.delete()

        try await monitoringStore.save(
            AccountCredential(email: "monitor@example.com", token: "read-only"),
            accountID: accountID
        )
        try await actionStore.save(PullRequestActionCredentialRecord(
            credential: AccountCredential(email: "actions@example.com", token: "write-pr"),
            expectedAccountID: accountID
        ))

        let action = try await actionStore.load()
        XCTAssertEqual(action?.expectedAccountID, accountID)
        XCTAssertEqual(action?.credential.email, "actions@example.com")
        XCTAssertEqual(action?.credential.token, "write-pr")

        try await actionStore.delete()
        let deletedAction = try await actionStore.load()
        let preservedMonitoringCredential = try await monitoringStore.load(accountID: accountID)
        XCTAssertNil(deletedAction)
        XCTAssertEqual(preservedMonitoringCredential?.token, "read-only")
        try await monitoringStore.delete(accountID: accountID)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("build-beacon-infrastructure-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func notificationEvent(repository: String = "repo", buildNumber: Int? = nil) -> NotificationEvent {
        NotificationEvent(
            kind: .failed,
            monitorID: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: repository),
                target: .defaultBranch
            ),
            runID: PipelineRunID(rawValue: "run"),
            buildNumber: buildNumber,
            title: "Pipeline failed",
            body: "Repository requires attention"
        )
    }

    private func approvalWaitMarker(repository: String, runID: String) -> ApprovalWaitMarker {
        ApprovalWaitMarker(
            monitorID: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: repository),
                target: .defaultBranch
            ),
            runID: PipelineRunID(rawValue: runID),
            firstDetectedAt: .now
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }
}

private struct LegacyLedgerEnvelope: Encodable {
    let schemaVersion = 1
    let entries: [NotificationLedgerEntry]
}

private final class NotificationCenterFake: UserNotificationCenterClient, @unchecked Sendable {
    var status: UNAuthorizationStatus
    private let alertsEnabled: Bool
    private let soundsEnabled: Bool
    private var recordedRequests: [UNNotificationRequest] = []
    private var categories: Set<UNNotificationCategory> = []
    private var requestCount = 0
    private var totalAdditions = 0
    private let lock = NSLock()

    init(
        status: UNAuthorizationStatus,
        alertsEnabled: Bool = true,
        soundsEnabled: Bool = true
    ) {
        self.status = status
        self.alertsEnabled = alertsEnabled
        self.soundsEnabled = soundsEnabled
    }

    var addedCount: Int { withLock { recordedRequests.count } }
    var totalAddedCount: Int { withLock { totalAdditions } }
    var pendingCount: Int { withLock { recordedRequests.count } }
    var allRequests: [UNNotificationRequest] { withLock { recordedRequests } }
    var authorizationRequests: Int { withLock { requestCount } }
    var categoryIdentifiers: Set<String> { withLock { Set(categories.map(\.identifier)) } }
    var openActionUsesForegroundPresentation: Bool {
        withLock {
            categories
                .first(where: { $0.identifier == UserNotificationService.categoryIdentifier })?
                .actions
                .contains(where: { $0.identifier == UserNotificationService.openActionIdentifier && $0.options.contains(.foreground) }) == true
        }
    }

    var approvalActionsAreForeground: Bool {
        withLock {
            let categories = categories.filter {
                $0.identifier == UserNotificationService.approvalCategoryIdentifier
                    || $0.identifier == UserNotificationService.approvalReminderCategoryIdentifier
            }
            return categories.allSatisfy { category in
                category.actions.contains(where: {
                    $0.identifier == UserNotificationService.openActionIdentifier && $0.options.contains(.foreground)
                }) && category.actions.contains(where: {
                    $0.identifier == UserNotificationService.openBitbucketActionIdentifier && $0.options.contains(.foreground)
                })
            }
        }
    }

    var approvalReminderPendingCount: Int {
        withLock {
            recordedRequests.count(where: {
                $0.content.categoryIdentifier == UserNotificationService.approvalReminderCategoryIdentifier
            })
        }
    }

    var approvalReminderIdentifiers: [String] {
        withLock {
            recordedRequests.compactMap { request in
                request.content.categoryIdentifier == UserNotificationService.approvalReminderCategoryIdentifier
                    ? request.identifier
                    : nil
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        withLock { requestCount += 1 }
        return status == .authorized || status == .provisional
    }

    func notificationPermissionStatus() async -> NotificationPermissionStatus {
        let authorization = withLock { Self.authorizationState(for: status) }
        return NotificationPermissionStatus(
            authorization: authorization,
            alertsEnabled: alertsEnabled,
            soundsEnabled: soundsEnabled
        )
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        withLock { self.categories = categories }
    }

    func add(_ request: UNNotificationRequest) async throws {
        withLock {
            recordedRequests.append(request)
            totalAdditions += 1
        }
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        withLock { recordedRequests }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        withLock {
            recordedRequests.removeAll(where: { identifiers.contains($0.identifier) })
        }
    }

    private static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unsupported
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
