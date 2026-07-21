import AppKit
import BuildBeaconKit
import Foundation
@preconcurrency import UserNotifications

/// Installs before notification delivery so foreground actions always have a route.
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let routeHandler: @MainActor @Sendable (NotificationRoute) -> Void

    init(routeHandler: @escaping @MainActor @Sendable (NotificationRoute) -> Void) {
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
        defer { completionHandler() }
        guard response.notification.request.content.categoryIdentifier == UserNotificationService.categoryIdentifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier
                || response.actionIdentifier == UserNotificationService.openActionIdentifier,
              let route = NotificationRoutePayload.route(
                from: response.notification.request.content.userInfo
              ) else {
            return
        }
        Task { @MainActor [routeHandler] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            routeHandler(route)
        }
    }
}
