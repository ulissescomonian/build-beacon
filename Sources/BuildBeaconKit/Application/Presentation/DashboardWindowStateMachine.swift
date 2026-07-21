/// Deterministic presentation policy for Build Beacon's single dashboard window.
///
/// The AppKit adapter owns `NSWindow` instances. This value only decides whether
/// a request creates, restores, focuses, or hides that one window, so duplicate
/// requests can be coalesced without depending on AppKit timing.
public struct DashboardWindowStateMachine: Sendable {
    public struct Generation: Hashable, Comparable, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct WindowToken: Hashable, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    public enum ActivationPolicy: Hashable, Sendable {
        case regular
        case accessory
    }

    public enum Phase: Hashable, Sendable {
        case hidden
        case opening(Generation)
        case visible(generation: Generation, token: WindowToken, isMinimized: Bool)
    }

    public enum Effect: Hashable, Sendable {
        /// Put the app in the Dock before presenting its dashboard.
        case setActivationPolicy(ActivationPolicy)
        /// Ask the AppKit adapter to create the window identified by this request.
        case create(Generation)
        /// Bring an existing non-minimized dashboard forward.
        case focus(WindowToken)
        /// Restore a minimized dashboard, then bring it forward.
        case restoreAndFocus(WindowToken)
        /// Dispose a window attached after its opening request became obsolete.
        case closeObsolete(WindowToken)
    }

    public private(set) var phase: Phase
    private var nextGeneration: UInt64

    public init() {
        phase = .hidden
        nextGeneration = 1
    }

    /// Coalesces repeated presentation requests while a dashboard is opening.
    public mutating func requestOpen() -> [Effect] {
        switch phase {
        case .hidden:
            let generation = Generation(rawValue: nextGeneration)
            nextGeneration &+= 1
            phase = .opening(generation)
            return [.setActivationPolicy(.regular), .create(generation)]

        case .opening:
            return []

        case let .visible(_, token, isMinimized):
            if isMinimized {
                phase = visiblePhase(token: token, isMinimized: false)
                return [.restoreAndFocus(token)]
            }
            return [.focus(token)]
        }
    }

    /// Attaches the AppKit window created for a particular opening generation.
    /// A late attachment is explicitly closed so it cannot become a duplicate.
    public mutating func attachWindow(
        token: WindowToken,
        for generation: Generation
    ) -> [Effect] {
        guard case let .opening(currentGeneration) = phase,
              currentGeneration == generation
        else {
            return [.closeObsolete(token)]
        }

        phase = .visible(generation: generation, token: token, isMinimized: false)
        return [.focus(token)]
    }

    /// Registers a legitimate singleton window restored independently by macOS.
    ///
    /// Scene restoration can supply an already-created dashboard while this
    /// state machine is hidden. That is distinct from a late attachment for an
    /// expired explicit opening request: an opening state must still use
    /// `attachWindow(token:for:)` with its matching generation.
    public mutating func adoptWindow(token: WindowToken) -> [Effect] {
        switch phase {
        case .hidden:
            let generation = Generation(rawValue: nextGeneration)
            nextGeneration &+= 1
            phase = .visible(generation: generation, token: token, isMinimized: false)
            return [.setActivationPolicy(.regular), .focus(token)]

        case .opening:
            return [.closeObsolete(token)]

        case let .visible(_, currentToken, _):
            guard currentToken != token else {
                return [.focus(token)]
            }
            return [.closeObsolete(token)]
        }
    }

    public mutating func setMinimized(_ isMinimized: Bool, for token: WindowToken) {
        guard case let .visible(generation, currentToken, _) = phase,
              currentToken == token
        else {
            return
        }

        phase = .visible(
            generation: generation,
            token: currentToken,
            isMinimized: isMinimized
        )
    }

    /// Handles a close notification. Notifications from obsolete windows are ignored.
    public mutating func closeWindow(token: WindowToken) -> [Effect] {
        guard case let .visible(_, currentToken, _) = phase,
              currentToken == token
        else {
            return []
        }

        phase = .hidden
        return [.setActivationPolicy(.accessory)]
    }

    /// Ends a pending creation after an AppKit failure or a presentation timeout.
    public mutating func failOpening(generation: Generation) -> [Effect] {
        guard case let .opening(currentGeneration) = phase,
              currentGeneration == generation
        else {
            return []
        }

        phase = .hidden
        return [.setActivationPolicy(.accessory)]
    }

    private func visiblePhase(token: WindowToken, isMinimized: Bool) -> Phase {
        guard case let .visible(generation, _, _) = phase else {
            preconditionFailure("A visible phase is required to update minimization state.")
        }
        return .visible(generation: generation, token: token, isMinimized: isMinimized)
    }
}
