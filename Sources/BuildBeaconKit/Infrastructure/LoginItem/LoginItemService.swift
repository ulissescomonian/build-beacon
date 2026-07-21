import ServiceManagement

public enum LoginItemState: Hashable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public final class LoginItemService {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    /// The system's status is always the source of truth; no mirrored preference
    /// is maintained by Build Beacon.
    public var state: LoginItemState {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try await service.unregister()
        }
    }
}
