import AppKit
import BuildBeaconKit
import Foundation
@preconcurrency import UserNotifications

/// Installs before notification delivery so foreground actions always have a route.
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Action: Sendable, Equatable {
        case openDashboard
        case openBitbucket
    }

    private let routeHandler: @MainActor @Sendable (NotificationRoute, Action) -> Void

    init(routeHandler: @escaping @MainActor @Sendable (NotificationRoute, Action) -> Void) {
        self.routeHandler = routeHandler
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let action = action(for: response),
              let route = NotificationRoutePayload.route(
                from: response.notification.request.content.userInfo
              ) else {
            completionHandler()
            return
        }
        let completion = NotificationCompletionHandler(completionHandler)
        Task { @MainActor [routeHandler, completion] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            routeHandler(route, action)
            completion.call()
        }
    }

    private func action(for response: UNNotificationResponse) -> Action? {
        let category = response.notification.request.content.categoryIdentifier
        let isPipelineEvent = category == UserNotificationService.categoryIdentifier
        let isApprovalEvent = category == UserNotificationService.approvalCategoryIdentifier
            || category == UserNotificationService.approvalReminderCategoryIdentifier
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, UserNotificationService.openActionIdentifier:
            return (isPipelineEvent || isApprovalEvent) ? .openDashboard : nil
        case UserNotificationService.openBitbucketActionIdentifier:
            return isApprovalEvent ? .openBitbucket : nil
        default:
            return nil
        }
    }
}

/// UserNotifications promises that this completion is invoked exactly once.
/// The delegate retains it only until the main-actor route handler has finished.
private final class NotificationCompletionHandler: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}
