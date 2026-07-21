import AppKit
import BuildBeaconKit
import SwiftUI

/// AppKit adapter for the deterministic single-window presentation policy.
///
/// The state machine owns coalescing and lifecycle decisions. This controller
/// owns only the concrete `NSWindow` references and their native effects.
@MainActor
final class DashboardPresentationController {
    typealias DashboardOpener = @MainActor () -> Void

    private var machine = DashboardWindowStateMachine()
    private var opener: DashboardOpener?
    private var hasPendingOpenRequest = false
    private var openingGeneration: DashboardWindowStateMachine.Generation?
    private var openingTimeoutTask: Task<Void, Never>?
    private var nextWindowToken: UInt64 = 1
    private var tokenByWindowIdentifier: [ObjectIdentifier: DashboardWindowStateMachine.WindowToken] = [:]
    private var windowByToken: [DashboardWindowStateMachine.WindowToken: WeakWindowReference] = [:]
    private var observersByToken: [DashboardWindowStateMachine.WindowToken: [NSObjectProtocol]] = [:]

    /// Registers the SwiftUI scene opener from an always-present scene bridge.
    func install(opener: @escaping DashboardOpener) {
        self.opener = opener
        guard hasPendingOpenRequest else { return }
        hasPendingOpenRequest = false
        openDashboard()
    }

    func openDashboard() {
        synchronizeMinimizationState()

        // There is no native scene opener yet. In particular, do not promote
        // an LSUIElement app to the Dock without a dashboard to present.
        if case .hidden = machine.phase, opener == nil {
            hasPendingOpenRequest = true
            return
        }

        hasPendingOpenRequest = false
        apply(machine.requestOpen())
    }

    /// Called by the content-view bridge when SwiftUI attaches to an NSWindow.
    func register(window: NSWindow) {
        let token = token(for: window)

        // SwiftUI may call `updateNSView` repeatedly while the dashboard is
        // already visible. Registration is not an explicit presentation
        // request, so it must never steal focus on an ordinary redraw.
        if case let .visible(_, currentToken, _) = machine.phase,
           currentToken == token {
            machine.setMinimized(window.isMiniaturized, for: token)
            return
        }

        let effects: [DashboardWindowStateMachine.Effect]
        if let openingGeneration {
            self.openingGeneration = nil
            openingTimeoutTask?.cancel()
            openingTimeoutTask = nil
            effects = machine.attachWindow(token: token, for: openingGeneration)
        } else {
            // A SwiftUI `Window` is a singleton. If its attachment arrives
            // after a timeout, it is still the legitimate dashboard scene,
            // not a second generation that should be closed.
            effects = machine.adoptWindow(token: token)
        }

        apply(effects)
        machine.setMinimized(window.isMiniaturized, for: token)
    }

    private func token(for window: NSWindow) -> DashboardWindowStateMachine.WindowToken {
        let identifier = ObjectIdentifier(window)
        if let token = tokenByWindowIdentifier[identifier] {
            return token
        }

        let token = DashboardWindowStateMachine.WindowToken(rawValue: nextWindowToken)
        nextWindowToken &+= 1
        tokenByWindowIdentifier[identifier] = token
        windowByToken[token] = WeakWindowReference(window)
        installObservers(for: window, token: token, identifier: identifier)
        return token
    }

    private func installObservers(
        for window: NSWindow,
        token: DashboardWindowStateMachine.WindowToken,
        identifier: ObjectIdentifier
    ) {
        let center = NotificationCenter.default
        let closeObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowWillClose(token: token, identifier: identifier)
            }
        }
        let miniaturizeObserver = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.machine.setMinimized(true, for: token)
            }
        }
        let deminiaturizeObserver = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.machine.setMinimized(false, for: token)
            }
        }
        observersByToken[token] = [closeObserver, miniaturizeObserver, deminiaturizeObserver]
    }

    private func windowWillClose(
        token: DashboardWindowStateMachine.WindowToken,
        identifier: ObjectIdentifier
    ) {
        removeTracking(token: token, identifier: identifier)
        apply(machine.closeWindow(token: token))
    }

    private func apply(_ effects: [DashboardWindowStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case let .setActivationPolicy(policy):
                setActivationPolicy(policy)

            case let .create(generation):
                createDashboard(for: generation)

            case let .focus(token):
                focusWindow(token: token, restore: false)

            case let .restoreAndFocus(token):
                focusWindow(token: token, restore: true)

            case let .closeObsolete(token):
                closeObsoleteWindow(token: token)
            }
        }
    }

    private func createDashboard(for generation: DashboardWindowStateMachine.Generation) {
        guard let opener else {
            apply(machine.failOpening(generation: generation))
            return
        }

        openingGeneration = generation
        scheduleOpeningTimeout(for: generation)
        opener()
    }

    private func scheduleOpeningTimeout(for generation: DashboardWindowStateMachine.Generation) {
        openingTimeoutTask?.cancel()
        openingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.openingDidTimeOut(generation: generation)
        }
    }

    private func openingDidTimeOut(generation: DashboardWindowStateMachine.Generation) {
        guard openingGeneration == generation else { return }
        openingGeneration = nil
        openingTimeoutTask = nil
        apply(machine.failOpening(generation: generation))
    }

    private func synchronizeMinimizationState() {
        guard case let .visible(_, token, _) = machine.phase,
              let window = windowByToken[token]?.window
        else {
            return
        }
        machine.setMinimized(window.isMiniaturized, for: token)
    }

    private func setActivationPolicy(_ policy: DashboardWindowStateMachine.ActivationPolicy) {
        switch policy {
        case .regular:
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        case .accessory:
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func focusWindow(token: DashboardWindowStateMachine.WindowToken, restore: Bool) {
        guard let window = windowByToken[token]?.window else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if restore || window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func closeObsoleteWindow(token: DashboardWindowStateMachine.WindowToken) {
        guard let window = windowByToken[token]?.window else { return }
        window.close()
    }

    private func removeTracking(
        token: DashboardWindowStateMachine.WindowToken,
        identifier: ObjectIdentifier
    ) {
        if let observers = observersByToken.removeValue(forKey: token) {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
        tokenByWindowIdentifier.removeValue(forKey: identifier)
        windowByToken.removeValue(forKey: token)
    }
}

private final class WeakWindowReference {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

/// Registers the `NSWindow` that hosts the SwiftUI dashboard without giving UI
/// code ownership of AppKit lifecycle state.
struct DashboardWindowRegistrationBridge: NSViewRepresentable {
    let presentation: DashboardPresentationController

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.presentation = presentation
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.presentation = presentation
        nsView.registerCurrentWindowIfNeeded()
    }

    final class WindowProbeView: NSView {
        weak var presentation: DashboardPresentationController?
        private weak var lastRegisteredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerCurrentWindowIfNeeded()
        }

        func registerCurrentWindowIfNeeded() {
            guard let window else { return }
            guard lastRegisteredWindow !== window else { return }
            lastRegisteredWindow = window
            presentation?.register(window: window)
        }
    }
}
