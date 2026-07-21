import Foundation

public enum ObservationFreshness: Hashable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum FreshnessPolicy {
    public static let minimumThreshold: TimeInterval = 120
    public static let maximumThreshold: TimeInterval = 900

    public static func threshold(refreshIntervalSeconds: Int) -> TimeInterval {
        min(max(Double(refreshIntervalSeconds) * 2, minimumThreshold), maximumThreshold)
    }

    public static func freshness(
        of observation: MonitorObservation,
        now: Date,
        refreshIntervalSeconds: Int
    ) -> ObservationFreshness {
        guard let lastSuccess = observation.lastSuccessfulObservationAt else {
            return .unavailable
        }
        if observation.currentFailure != nil { return .stale }
        if now.timeIntervalSince(lastSuccess) > threshold(refreshIntervalSeconds: refreshIntervalSeconds) {
            return .stale
        }
        return .fresh
    }
}

public enum AggregateStateReducer {
    public static func reduce(
        isConnected: Bool,
        observations: [MonitorID: MonitorObservation],
        now: Date,
        refreshIntervalSeconds: Int
    ) -> AggregateState {
        guard isConnected else { return .notConnected }
        guard !observations.isEmpty else { return .configuredWithoutMonitors }

        let values = Array(observations.values)
        if values.contains(where: requiresAttention) { return .attentionRequired }
        if values.contains(where: {
            FreshnessPolicy.freshness(of: $0, now: now, refreshIntervalSeconds: refreshIntervalSeconds) == .unavailable
        }) { return .unavailable }
        if values.contains(where: {
            FreshnessPolicy.freshness(of: $0, now: now, refreshIntervalSeconds: refreshIntervalSeconds) == .stale
        }) { return .stale }
        if values.contains(where: { $0.lastKnownRun?.phase == .awaitingApproval }) { return .awaitingApproval }
        if values.contains(where: {
            guard let phase = $0.lastKnownRun?.phase else { return false }
            return phase == .running || phase == .queued
        }) { return .running }

        // Healthy is intentionally proven, not inferred.
        if values.allSatisfy({ $0.lastKnownRun?.phase == .succeeded }) { return .healthy }
        return .unavailable
    }

    private static func requiresAttention(_ observation: MonitorObservation) -> Bool {
        if case .invalidCredentials? = observation.currentFailure { return true }
        guard let phase = observation.lastKnownRun?.phase else { return false }
        return switch phase {
        case .failed, .errored, .expired, .stopped, .unknown: true
        case .queued, .running, .awaitingApproval, .succeeded: false
        }
    }
}
