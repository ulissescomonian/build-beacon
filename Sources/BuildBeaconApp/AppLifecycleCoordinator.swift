import AppKit
import BuildBeaconKit
import BuildBeaconUI
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppLifecycleCoordinator {
    private let model: AppModel
    private let dashboardPresentation: DashboardPresentationController
    private let eventSource: NativeLifecycleEventSource
    private let notificationDelegate: NotificationCenterDelegate
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshReason: RefreshReason?
    private var lastActivationRefreshAt: Date?
    private var isStarted = false
    private let activationThrottle: TimeInterval = 15

    init(
        model: AppModel,
        dashboardPresentation: DashboardPresentationController,
        eventSource: NativeLifecycleEventSource = NativeLifecycleEventSource()
    ) {
        self.model = model
        self.dashboardPresentation = dashboardPresentation
        self.eventSource = eventSource
        self.notificationDelegate = NotificationCenterDelegate { [weak model, weak dashboardPresentation] route, action in
            guard let model else { return }
            model.handleNotificationRoute(route)
            dashboardPresentation?.openDashboard()
            if action == .openBitbucket {
                model.openPipelineBuildURL(for: route)
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        model.startIfNeeded()
        eventSource.start { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        eventSource.stop()
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefreshReason = nil
        if UNUserNotificationCenter.current().delegate === notificationDelegate {
            UNUserNotificationCenter.current().delegate = nil
        }
    }

    private func handle(_ event: NativeLifecycleEvent) {
        model.startIfNeeded()
        switch event {
        case .activation:
            let now = Date()
            guard lastActivationRefreshAt.map({ now.timeIntervalSince($0) >= activationThrottle }) ?? true else {
                return
            }
            lastActivationRefreshAt = now
            requestRefresh(reason: .activation)
        case .wake:
            requestRefresh(reason: .wake)
        case .networkRecovery:
            requestRefresh(reason: .networkRecovery)
        }
    }

    private func requestRefresh(reason: RefreshReason) {
        if refreshTask != nil {
            pendingRefreshReason = merged(pendingRefreshReason, reason)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await model.refresh(reason: reason)
            finishRefresh()
        }
        refreshTask = task
    }

    private func finishRefresh() {
        refreshTask = nil
        guard let pendingRefreshReason else { return }
        self.pendingRefreshReason = nil
        requestRefresh(reason: pendingRefreshReason)
    }

    private func merged(_ current: RefreshReason?, _ incoming: RefreshReason) -> RefreshReason {
        guard let current else { return incoming }
        return refreshPriority(incoming) > refreshPriority(current) ? incoming : current
    }

    private func refreshPriority(_ reason: RefreshReason) -> Int {
        switch reason {
        case .configurationChanged: 7
        case .manual: 6
        case .wake: 5
        case .networkRecovery: 4
        case .activation: 3
        case .retry: 2
        case .startup: 1
        case .scheduled: 0
        }
    }
}
