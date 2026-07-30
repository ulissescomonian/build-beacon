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
        case "STOPPED", "CANCELLED", "CANCELED", "NOT_RUN": return .stopped
        default: break
        }

        switch state {
        case "PENDING", "QUEUED", "READY": return .queued
        case "IN_PROGRESS", "RUNNING": return .running
        case "PAUSED", "HALTED", "AWAITING_APPROVAL", "WAITING_FOR_APPROVAL": return .awaitingApproval
        case "COMPLETED":
            // A completed run without an explicit result is deliberately unknown.
            return .unknown(remoteState: remoteState, remoteResult: remoteResult)
        case "STOPPED", "CANCELLED", "CANCELED": return .stopped
        default: return .unknown(remoteState: remoteState, remoteResult: remoteResult)
        }
    }

    /// Converts a remote step into its app phase. A pending manual trigger is
    /// represented as an approval request, while all other state/result pairs
    /// retain their usual mapping.
    public static func reduceStep(
        remoteState: String?,
        remoteResult: String?,
        requiresManualTrigger: Bool = false
    ) -> PipelineStepPhase {
        let pipelinePhase = reduce(remoteState: remoteState, remoteResult: remoteResult)
        if pipelinePhase == .queued, requiresManualTrigger {
            return .awaitingApproval
        }

        return switch pipelinePhase {
        case .queued: .queued
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .succeeded: .succeeded
        case .failed, .errored, .expired: .failed
        case .stopped: .stopped
        case .unknown: .unknown
        }
    }

    /// Reconciles an in-progress pipeline with its ordered steps. Terminal and
    /// otherwise explicit pipeline phases always remain authoritative.
    public static func resolve(
        pipelinePhase: PipelinePhase,
        stepPhases: [PipelineStepPhase]
    ) -> PipelinePhase {
        guard pipelinePhase == .running else { return pipelinePhase }

        if stepPhases.contains(.running) {
            return .running
        }

        let firstActiveStep = stepPhases.first { phase in
            switch phase {
            case .queued, .running, .awaitingApproval:
                true
            case .succeeded, .failed, .stopped, .unknown:
                false
            }
        }

        if firstActiveStep == .awaitingApproval {
            return .awaitingApproval
        }
        return .running
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
