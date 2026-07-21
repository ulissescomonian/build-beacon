import Foundation

public enum NotificationPolicy {
    public static func events(
        previous: MonitoringSnapshot?,
        current: MonitoringSnapshot,
        configuration: AppConfiguration
    ) -> [NotificationEvent] {
        guard configuration.notificationsEnabled, let previous else { return [] }

        let sortedIDs = current.observations.keys.sorted(by: { stableKey($0) < stableKey($1) })
        var result: [NotificationEvent] = []

        // Authentication is an account-level condition. Select one deterministic monitor
        // as the routing anchor instead of emitting the same alert for every repository.
        let accountID = configuration.account?.id
        let previousHadAuthenticationFailure = previous.observations.values.contains {
            $0.monitor.id.accountID == accountID && isAuthenticationFailure($0.currentFailure)
        }
        if !previousHadAuthenticationFailure,
           let authenticationObservation = sortedIDs.lazy
               .compactMap({ current.observations[$0] })
               .first(where: {
                   $0.monitor.id.accountID == accountID && isAuthenticationFailure($0.currentFailure)
               }) {
            result.append(event(.authenticationRequired, observation: authenticationObservation))
        }

        for id in sortedIDs {
            guard let currentObservation = current.observations[id] else { continue }
            let old = previous.observations[id]

            if isAuthenticationFailure(currentObservation.currentFailure) { continue }

            let currentPhase = currentObservation.lastKnownRun?.phase
            let oldPhase = old?.lastKnownRun?.phase
            let isNewRun = old?.lastKnownRun?.id != currentObservation.lastKnownRun?.id

            if configuration.notifyOnFailure,
               isFailed(currentPhase), (!isFailed(oldPhase) || isNewRun) {
                result.append(event(.failed, observation: currentObservation))
                continue
            }
            // A recovery is semantically distinct from a routine successful run.
            // Always consume it here so a favorite never receives both alerts.
            if currentPhase == .succeeded, isFailed(oldPhase) {
                if configuration.notifyOnRecovery {
                    result.append(event(.recovered, observation: currentObservation))
                }
                continue
            }
            if configuration.notifyOnFavoriteSuccess,
               currentObservation.monitor.isFavorite,
               currentPhase == .succeeded,
               isNewRun || oldPhase != .succeeded {
                result.append(event(.succeeded, observation: currentObservation))
                continue
            }
            if configuration.notifyOnApproval,
               currentPhase == .awaitingApproval,
               oldPhase != .awaitingApproval || isNewRun {
                result.append(event(.awaitingApproval, observation: currentObservation))
            }
        }
        return result
    }

    private static func isFailed(_ phase: PipelinePhase?) -> Bool {
        guard let phase else { return false }
        return switch phase {
        case .failed, .errored, .expired: true
        default: false
        }
    }

    private static func isAuthenticationFailure(_ failure: ObservationFailure?) -> Bool {
        switch failure {
        case .invalidCredentials?, .insufficientPermissions?: true
        default: false
        }
    }

    private static func event(_ kind: NotificationEventKind, observation: MonitorObservation) -> NotificationEvent {
        let repository = observation.monitor.repositoryName
        let run = observation.lastKnownRun
        switch kind {
        case .failed:
            return .init(kind: kind, monitorID: observation.monitor.id, runID: run?.id, buildNumber: run?.buildNumber,
                         title: "Build failed", body: "\(repository) #\(run?.buildNumber ?? 0) requires attention.")
        case .recovered:
            return .init(kind: kind, monitorID: observation.monitor.id, runID: run?.id, buildNumber: run?.buildNumber,
                         title: "Build recovered", body: "\(repository) is healthy again.")
        case .succeeded:
            return .init(kind: kind, monitorID: observation.monitor.id, runID: run?.id, buildNumber: run?.buildNumber,
                         title: "Favorite build succeeded", body: "\(repository) #\(run?.buildNumber ?? 0) completed successfully.")
        case .awaitingApproval:
            return .init(kind: kind, monitorID: observation.monitor.id, runID: run?.id, buildNumber: run?.buildNumber,
                         title: "Approval required", body: "\(repository) is waiting for approval.")
        case .authenticationRequired:
            return .init(kind: kind, monitorID: observation.monitor.id, runID: run?.id, buildNumber: run?.buildNumber,
                         title: "Reconnect account", body: "Build Beacon can no longer access \(repository).")
        }
    }

    private static func stableKey(_ id: MonitorID) -> String {
        "\(id.workspaceID.rawValue)/\(id.repositoryID.rawValue)/\(id.target.displayName)"
    }
}
