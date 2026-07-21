import Foundation

/// Converts remote state/result pairs into the closed set understood by the app.
/// Only an explicit successful result can produce `.succeeded`.
public enum PipelineStateReducer {
    public static func reduce(remoteState: String?, remoteResult: String?) -> PipelinePhase {
        let state = normalized(remoteState)
        let result = normalized(remoteResult)

        switch result {
        case "SUCCESSFUL", "SUCCESS", "SUCCEEDED": return .succeeded
        case "FAILED", "FAILURE": return .failed
        case "ERROR", "ERRORED": return .errored
        case "EXPIRED": return .expired
        case "STOPPED", "CANCELLED", "CANCELED": return .stopped
        default: break
        }

        switch state {
        case "PENDING", "QUEUED": return .queued
        case "IN_PROGRESS", "RUNNING": return .running
        case "PAUSED", "HALTED", "AWAITING_APPROVAL", "WAITING_FOR_APPROVAL": return .awaitingApproval
        case "COMPLETED":
            // A completed run without an explicit result is deliberately unknown.
            return .unknown(remoteState: remoteState, remoteResult: remoteResult)
        case "STOPPED", "CANCELLED", "CANCELED": return .stopped
        default: return .unknown(remoteState: remoteState, remoteResult: remoteResult)
        }
    }

    public static func reduceStep(remoteState: String?, remoteResult: String?) -> PipelineStepPhase {
        switch reduce(remoteState: remoteState, remoteResult: remoteResult) {
        case .queued: .queued
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .succeeded: .succeeded
        case .failed, .errored, .expired: .failed
        case .stopped: .stopped
        case .unknown: .unknown
        }
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
