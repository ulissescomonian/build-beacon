import Foundation

/// Reduces successful monitor observations into the small durable state needed
/// to measure one outstanding approval wait. Failed observations deliberately
/// leave state untouched because they cannot prove that a pipeline advanced.
public enum ApprovalWaitStateReducer {
    public static func reduce(
        markers: [ApprovalWaitMarker],
        observations: [MonitorID: MonitorObservation],
        activeMonitorIDs: Set<MonitorID>,
        detectedAt: Date
    ) -> [ApprovalWaitMarker] {
        var markerByIdentity: [ApprovalReminderIdentity: ApprovalWaitMarker] = [:]
        for marker in markers where activeMonitorIDs.contains(marker.monitorID) {
            if let existing = markerByIdentity[marker.identity] {
                if marker.firstDetectedAt < existing.firstDetectedAt {
                    markerByIdentity[marker.identity] = marker
                }
            } else {
                markerByIdentity[marker.identity] = marker
            }
        }

        for (monitorID, observation) in observations where activeMonitorIDs.contains(monitorID) {
            // An unavailable API response is not a state transition.
            guard observation.currentFailure == nil else { continue }

            guard let run = observation.lastKnownRun,
                  run.phase == .awaitingApproval else {
                markerByIdentity = markerByIdentity.filter { $0.key.monitorID != monitorID }
                continue
            }

            markerByIdentity = markerByIdentity.filter {
                $0.key.monitorID != monitorID || $0.key.runID == run.id
            }
            let identity = ApprovalReminderIdentity(monitorID: monitorID, runID: run.id)
            if markerByIdentity[identity] == nil {
                markerByIdentity[identity] = ApprovalWaitMarker(
                    monitorID: monitorID,
                    runID: run.id,
                    firstDetectedAt: detectedAt
                )
            }
        }

        return markerByIdentity.values.sorted { lhs, rhs in
            if lhs.firstDetectedAt != rhs.firstDetectedAt {
                return lhs.firstDetectedAt < rhs.firstDetectedAt
            }
            let left = stableKey(lhs.identity)
            let right = stableKey(rhs.identity)
            return left < right
        }
    }

    private static func stableKey(_ identity: ApprovalReminderIdentity) -> String {
        let monitor = identity.monitorID
        return "\(monitor.accountID.rawValue)/\(monitor.workspaceID.rawValue)/\(monitor.repositoryID.rawValue)/\(monitor.target.displayName)/\(identity.runID.rawValue)"
    }
}
