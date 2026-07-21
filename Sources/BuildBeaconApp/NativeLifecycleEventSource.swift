import AppKit
import Foundation
import Network

enum NativeLifecycleEvent: Sendable {
    case wake
    case activation
    case networkRecovery
}

/// Bridges process and network lifecycle signals into a small, testable event stream.
/// The source deliberately treats only an actual offline-to-online transition as a
/// recovery; the first path callback merely establishes the baseline.
@MainActor
final class NativeLifecycleEventSource {
    private let notificationCenter: NotificationCenter
    private let workspace: NSWorkspace
    private let pathMonitor: NWPathMonitor
    private let pathQueue = DispatchQueue(label: "com.epyczones.buildbeacon.network-path")
    private var observerTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var previousPathStatus: NWPath.Status?
    private var handler: (@Sendable (NativeLifecycleEvent) -> Void)?
    private var isStarted = false

    init(
        notificationCenter: NotificationCenter = .default,
        workspace: NSWorkspace = .shared,
        pathMonitor: NWPathMonitor = NWPathMonitor()
    ) {
        self.notificationCenter = notificationCenter
        self.workspace = workspace
        self.pathMonitor = pathMonitor
    }

    func start(handler: @escaping @Sendable (NativeLifecycleEvent) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.handler = handler

        let workspaceNotificationCenter = workspace.notificationCenter
        let wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(.wake) }
        }
        let activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(.activation) }
        }
        observerTokens = [
            (center: workspaceNotificationCenter, token: wakeObserver),
            (center: notificationCenter, token: activationObserver)
        ]

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePathStatus(path.status) }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func stop() {
        guard isStarted else { return }
        observerTokens.forEach { $0.center.removeObserver($0.token) }
        observerTokens.removeAll()
        pathMonitor.cancel()
        handler = nil
        isStarted = false
    }

    private func handlePathStatus(_ status: NWPath.Status) {
        defer { previousPathStatus = status }
        guard let previousPathStatus,
              previousPathStatus != .satisfied,
              status == .satisfied else { return }
        emit(.networkRecovery)
    }

    private func emit(_ event: NativeLifecycleEvent) {
        handler?(event)
    }

    deinit {
        pathMonitor.cancel()
    }
}
