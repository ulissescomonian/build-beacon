import Foundation
@preconcurrency import UserNotifications

public enum UserNotificationServiceError: Error, Equatable, Sendable {
    case authorizationDenied
}

public enum NotificationRoutePayload {
    public static let userInfoKey = "notificationRoute"

    public static func makeUserInfo(for route: NotificationRoute) throws -> [AnyHashable: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(route)
        return [Self.userInfoKey: data.base64EncodedString()]
    }

    public static func route(from userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let encodedRoute = userInfo[Self.userInfoKey] as? String,
              let data = Data(base64Encoded: encodedRoute) else {
            return nil
        }
        return try? JSONDecoder().decode(NotificationRoute.self, from: data)
    }
}

public protocol UserNotificationCenterClient: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationPermissionStatus() async -> NotificationPermissionStatus
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequests() async -> [UNNotificationRequest]
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}

public struct SystemUserNotificationCenterClient: UserNotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    public func notificationPermissionStatus() async -> NotificationPermissionStatus {
        let settings = await center.notificationSettings()
        return NotificationPermissionStatus(
            authorization: Self.authorizationState(from: settings.authorizationStatus),
            alertsEnabled: settings.alertSetting == .enabled,
            soundsEnabled: settings.soundSetting == .enabled
        )
    }

    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        center.setNotificationCategories(categories)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    public func pendingRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    public func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func authorizationState(
        from status: UNAuthorizationStatus
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
}

public actor UserNotificationService: NotificationSending {
    public static let categoryIdentifier = "BUILD_BEACON_PIPELINE_EVENT"
    public static let openActionIdentifier = "BUILD_BEACON_OPEN"
    public static let approvalCategoryIdentifier = "BUILD_BEACON_APPROVAL_EVENT"
    public static let approvalReminderCategoryIdentifier = "BUILD_BEACON_APPROVAL_REMINDER"
    public static let openBitbucketActionIdentifier = "BUILD_BEACON_OPEN_BITBUCKET"

    private let center: any UserNotificationCenterClient
    private let ledger: NotificationLedger?
    private var inMemoryApprovalReminderRecords = Set<ApprovalReminderRecord>()

    public init(
        center: any UserNotificationCenterClient = SystemUserNotificationCenterClient(),
        ledger: NotificationLedger? = nil
    ) {
        self.center = center
        self.ledger = ledger
    }

    public func configureCategories() async throws {
        await center.setNotificationCategories(Self.categories)
    }

    public func permissionStatus() async throws -> NotificationPermissionStatus {
        await center.notificationPermissionStatus()
    }

    public func requestAuthorization() async throws -> NotificationPermissionStatus {
        try await configureCategories()
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return try await permissionStatus()
    }

    public func deliverTest(route: NotificationRoute) async throws {
        try await configureCategories()
        try await ensureDeliveryAuthorization()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Build Beacon notifications are working")
        content.body = String(localized: "This is a test notification for the selected pipeline.")
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = try NotificationRoutePayload.makeUserInfo(for: route)

        let request = UNNotificationRequest(
            identifier: "build-beacon.test.\(UUID().uuidString.lowercased())",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    public func deliver(_ event: NotificationEvent) async throws {
        if let ledger, try await ledger.contains(event) {
            return
        }

        try await configureCategories()
        try await ensureDeliveryAuthorization()

        let route = NotificationRoute(
            monitorID: event.monitorID,
            runID: event.runID,
            buildNumber: event.buildNumber
        )
        let monitorKey = try Self.monitorKey(for: event.monitorID)
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier(for: event.kind)
        content.userInfo = try NotificationRoutePayload.makeUserInfo(for: route)

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier(for: event, monitorKey: monitorKey),
            content: content,
            trigger: nil
        )
        try await center.add(request)
        try await ledger?.record(event)
    }

    public func removePending(for monitorID: MonitorID) async {
        let pending = await center.pendingRequests()
        let identifiers = pending.compactMap { request -> String? in
            NotificationRoutePayload.route(from: request.content.userInfo)?.monitorID == monitorID
                ? request.identifier
                : nil
        }
        if !identifiers.isEmpty {
            await center.removePendingRequests(withIdentifiers: identifiers)
        }
        try? await ledger?.remove(for: monitorID)
    }

    /// Keeps one local, opt-in reminder per approval wait. The reminder route
    /// intentionally carries only opaque monitor and run identifiers, never a
    /// remote URL or pipeline payload.
    public func reconcileApprovalReminders(
        activeApprovals: [ApprovalWaitMarker],
        interval: ApprovalReminderInterval
    ) async {
        let pending = await center.pendingRequests()
        let reminders = pending.filter {
            $0.content.categoryIdentifier == Self.approvalReminderCategoryIdentifier
        }

        guard let duration = interval.duration else {
            if !reminders.isEmpty {
                await center.removePendingRequests(withIdentifiers: reminders.map(\.identifier))
            }
            inMemoryApprovalReminderRecords.removeAll()
            try? await ledger?.reconcileApprovalReminders(activeIdentities: [], interval: .none)
            return
        }

        let activeIdentities = Set(activeApprovals.map(\.identity))
        try? await ledger?.reconcileApprovalReminders(
            activeIdentities: activeIdentities,
            interval: interval
        )
        inMemoryApprovalReminderRecords = inMemoryApprovalReminderRecords.filter {
            activeIdentities.contains($0.identity) && $0.interval == interval
        }
        var scheduled = Set<ApprovalReminderIdentity>()
        var staleIdentifiers: [String] = []
        for request in reminders {
            guard let route = NotificationRoutePayload.route(from: request.content.userInfo),
                  let runID = route.runID else {
                staleIdentifiers.append(request.identifier)
                continue
            }
            let identity = ApprovalReminderIdentity(monitorID: route.monitorID, runID: runID)
            guard activeIdentities.contains(identity),
                  request.identifier == (try? Self.approvalReminderRequestIdentifier(
                    for: identity,
                    duration: duration
                  )) else {
                staleIdentifiers.append(request.identifier)
                continue
            }
            scheduled.insert(identity)
        }
        if !staleIdentifiers.isEmpty {
            await center.removePendingRequests(withIdentifiers: staleIdentifiers)
        }

        guard await isAuthorizedForDelivery() else { return }
        await center.setNotificationCategories(Self.categories)
        var considered = Set<ApprovalReminderIdentity>()
        for marker in activeApprovals where considered.insert(marker.identity).inserted {
            guard !scheduled.contains(marker.identity) else { continue }
            let record = ApprovalReminderRecord(identity: marker.identity, interval: interval)
            let wasRecorded: Bool
            if let ledger {
                wasRecorded = (try? await ledger.containsApprovalReminder(marker.identity, interval: interval)) ?? false
            } else {
                wasRecorded = inMemoryApprovalReminderRecords.contains(record)
            }
            guard !wasRecorded else { continue }
            do {
                try await scheduleApprovalReminder(marker, after: duration)
                if let ledger {
                    try await ledger.recordApprovalReminder(marker.identity, interval: interval)
                } else {
                    inMemoryApprovalReminderRecords.insert(record)
                }
            } catch {
                // A reminder is a best-effort local convenience. The immediate
                // transition alert and the dashboard remain available on failure.
            }
        }
    }

    private func ensureDeliveryAuthorization() async throws {
        let status = try await permissionStatus()
        guard status.authorization == .authorized
                || status.authorization == .provisional
                || status.authorization == .ephemeral else {
            throw UserNotificationServiceError.authorizationDenied
        }
    }

    private func isAuthorizedForDelivery() async -> Bool {
        guard let status = try? await permissionStatus() else { return false }
        return switch status.authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    private func scheduleApprovalReminder(
        _ marker: ApprovalWaitMarker,
        after duration: TimeInterval
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Approval still required")
        content.body = String(localized: "A pipeline is still waiting for approval.")
        content.sound = .default
        content.categoryIdentifier = Self.approvalReminderCategoryIdentifier
        content.userInfo = try NotificationRoutePayload.makeUserInfo(
            for: NotificationRoute(monitorID: marker.monitorID, runID: marker.runID)
        )

        let remaining = max(1, marker.firstDetectedAt.addingTimeInterval(duration).timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: try Self.approvalReminderRequestIdentifier(for: marker.identity, duration: duration),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        )
        try await center.add(request)
    }

    private static func monitorKey(for monitorID: MonitorID) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(monitorID)
        return data.base64EncodedString()
    }

    private static func requestIdentifier(for event: NotificationEvent, monitorKey: String) -> String {
        let run = event.runID?.rawValue ?? "none"
        return "build-beacon.\(stableHash(monitorKey)).\(event.kind.rawValue).\(stableHash(run))"
    }

    private static func approvalReminderRequestIdentifier(
        for identity: ApprovalReminderIdentity,
        duration: TimeInterval
    ) throws -> String {
        let monitorKey = try Self.monitorKey(for: identity.monitorID)
        return "build-beacon.\(stableHash(monitorKey)).approval-reminder.\(stableHash(identity.runID.rawValue)).\(Int(duration))"
    }

    private static func categoryIdentifier(for kind: NotificationEventKind) -> String {
        kind == .awaitingApproval ? approvalCategoryIdentifier : categoryIdentifier
    }

    private static var categories: Set<UNNotificationCategory> {
        let openAction = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: String(localized: "Open Build Beacon"),
            options: [.foreground]
        )
        let pipelineCategory = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let openBitbucketAction = UNNotificationAction(
            identifier: Self.openBitbucketActionIdentifier,
            title: String(localized: "Open in Bitbucket"),
            options: [.foreground]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategoryIdentifier,
            actions: [openAction, openBitbucketAction],
            intentIdentifiers: [],
            options: []
        )
        let approvalReminderCategory = UNNotificationCategory(
            identifier: Self.approvalReminderCategoryIdentifier,
            actions: [openAction, openBitbucketAction],
            intentIdentifiers: [],
            options: []
        )
        return [pipelineCategory, approvalCategory, approvalReminderCategory]
    }

    /// FNV-1a is used only for stable, compact system identifiers; it is not a
    /// cryptographic or privacy boundary.
    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private struct ApprovalReminderRecord: Hashable {
    let identity: ApprovalReminderIdentity
    let interval: ApprovalReminderInterval
}
