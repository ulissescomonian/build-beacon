import Foundation

/// Pure scheduling rules for pipeline observations. The engine owns the mutable
/// calendar; this type only turns an observation into its next deadline.
public enum PollingPolicy {
    public static let activeMaximumInterval: TimeInterval = 30
    public static let approvalMinimumInterval: TimeInterval = 120
    public static let initialRetryDelay: TimeInterval = 30
    public static let maximumRetryDelay: TimeInterval = 900
    public static let rateLimitFallbackDelay: TimeInterval = 60

    public static func normalInterval(_ configuredInterval: Int) -> TimeInterval {
        TimeInterval(max(30, configuredInterval))
    }

    public static func deadline(
        for observation: MonitorObservation,
        now: Date,
        configuredInterval: Int,
        retryAttempt: Int = 0
    ) -> Date {
        if requiresIndividualBackoff(observation.currentFailure) {
            return now.addingTimeInterval(backoffDelay(attempt: retryAttempt))
        }

        let normal = normalInterval(configuredInterval)
        let interval: TimeInterval
        switch observation.lastKnownRun?.phase {
        case .queued?, .running?:
            interval = min(normal, activeMaximumInterval)
        case .awaitingApproval?:
            interval = max(normal, approvalMinimumInterval)
        default:
            interval = normal
        }
        return now.addingTimeInterval(interval)
    }

    public static func backoffDelay(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 5)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }

    public static func isAuthenticationFailure(_ failure: ObservationFailure?) -> Bool {
        switch failure {
        case .invalidCredentials?, .insufficientPermissions?: true
        default: false
        }
    }

    public static func rateLimitDeadline(
        for failure: ObservationFailure?,
        now: Date,
        attempt: Int
    ) -> Date? {
        guard case let .rateLimited(retryAt)? = failure else { return nil }
        if let retryAt, retryAt > now { return retryAt }
        let exponent = min(max(attempt - 1, 0), 4)
        let fallback = min(rateLimitFallbackDelay * pow(2, Double(exponent)), maximumRetryDelay)
        return now.addingTimeInterval(fallback)
    }

    public static func requiresIndividualBackoff(_ failure: ObservationFailure?) -> Bool {
        switch failure {
        case .offline?, .timedOut?, .unexpected?: true
        case let .server(status)?: (500...599).contains(status)
        default: false
        }
    }
}
