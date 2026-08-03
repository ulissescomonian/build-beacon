import BuildBeaconKit
import Foundation

public struct PullRequestMergeReadinessDisplay: Equatable {
    let target: PullRequestActionTarget?
    let badgeTitle: String?
    let detail: String?
    let accessibilityLabel: String?

    var isReady: Bool { target != nil }
}

struct PullRequestMergeResultDisplay: Equatable {
    enum Kind: Equatable {
        case merged
        case approvedButNotMerged
        case unknown
        case failed
    }

    let kind: Kind
    let title: String
    let message: String
    let symbolName: String
}

enum PullRequestMergePresentation {
    static func readiness(
        for observation: MonitorObservation,
        actionsConfigured: Bool = true
    ) -> PullRequestMergeReadinessDisplay {
        guard actionsConfigured else {
            return PullRequestMergeReadinessDisplay(
                target: nil,
                badgeTitle: nil,
                detail: nil,
                accessibilityLabel: nil
            )
        }
        switch PullRequestMergeEligibilityEvaluator.evaluate(observation) {
        case let .eligible(target):
            let format = String(
                localized: "pullRequest.merge.ready.accessibility.format",
                defaultValue: "Pull request #%lld is ready to merge",
                bundle: .module
            )
            return PullRequestMergeReadinessDisplay(
                target: target,
                badgeTitle: String(localized: "Ready to merge", bundle: .module),
                detail: String(localized: "All merge prerequisites are available.", bundle: .module),
                accessibilityLabel: String(format: format, Int64(target.pullRequestID))
            )
        case .ineligible:
            return PullRequestMergeReadinessDisplay(
                target: nil,
                badgeTitle: nil,
                detail: nil,
                accessibilityLabel: nil
            )
        }
    }

    static func actionAccessibilityLabel(target: PullRequestActionTarget, repositoryName: String) -> String {
        let format = String(
            localized: "pullRequest.merge.action.accessibility.format",
            defaultValue: "Approve and merge pull request #%lld for %@",
            bundle: .module
        )
        return String(format: format, Int64(target.pullRequestID), repositoryName)
    }

    static func strategyTitle(_ strategy: PullRequestMergeStrategy) -> String {
        switch strategy {
        case .mergeCommit: String(localized: "Merge commit", bundle: .module)
        case .squash: String(localized: "Squash", bundle: .module)
        case .fastForward: String(localized: "Fast-forward", bundle: .module)
        }
    }

    static func confirmationMessage(
        preflight: PullRequestMergePreflight,
        accountName: String
    ) -> String {
        let format = String(
            localized: "pullRequest.merge.confirmation.message.format",
            defaultValue: "This approves PR #%lld as %@ and then merges it into %@. Build Beacon cannot undo this action.",
            bundle: .module
        )
        return String(
            format: format,
            Int64(preflight.target.pullRequestID),
            accountName,
            preflight.target.destinationBranch
        )
    }

    static func operationTitle(_ phase: PullRequestActionOperationPhase) -> String {
        switch phase {
        case .idle, .awaitingConfirmation:
            String(localized: "Preparing pull request action…", bundle: .module)
        case .preflighting:
            String(localized: "Checking merge readiness…", bundle: .module)
        case .revalidatingBeforeApproval:
            String(localized: "Revalidating before approval…", bundle: .module)
        case .approving:
            String(localized: "Approving pull request…", bundle: .module)
        case .revalidatingBeforeMerge:
            String(localized: "Revalidating before merge…", bundle: .module)
        case .merging:
            String(localized: "Merging pull request…", bundle: .module)
        case .waitingForProvider:
            String(localized: "Verifying merge with Bitbucket…", bundle: .module)
        case .completed:
            String(localized: "Merge completed", bundle: .module)
        case .blocked:
            String(localized: "Merge blocked", bundle: .module)
        case .failed:
            String(localized: "Merge failed", bundle: .module)
        }
    }

    static func outcome(_ outcome: PullRequestMergeOutcome) -> PullRequestMergeResultDisplay {
        switch outcome {
        case let .merged(mergeCommitHash):
            let message: String
            if let mergeCommitHash, !mergeCommitHash.isEmpty {
                let format = String(
                    localized: "pullRequest.merge.success.commit.format",
                    defaultValue: "Bitbucket confirmed the merge. Merge commit: %@",
                    bundle: .module
                )
                message = String(format: format, String(mergeCommitHash.prefix(12)))
            } else {
                message = String(localized: "Bitbucket confirmed the pull request was merged.", bundle: .module)
            }
            return PullRequestMergeResultDisplay(
                kind: .merged,
                title: String(localized: "Pull request merged", bundle: .module),
                message: message,
                symbolName: "checkmark.circle.fill"
            )
        case let .approvedButNotMerged(reason):
            return PullRequestMergeResultDisplay(
                kind: .approvedButNotMerged,
                title: String(localized: "Approved, but not merged", bundle: .module),
                message: approvedButNotMergedMessage(reason),
                symbolName: "exclamationmark.circle.fill"
            )
        case .outcomeUnknown:
            return PullRequestMergeResultDisplay(
                kind: .unknown,
                title: String(localized: "Merge outcome unknown", bundle: .module),
                message: String(
                    localized: "Build Beacon could not confirm the final state. Review the pull request in Bitbucket before trying again.",
                    bundle: .module
                ),
                symbolName: "questionmark.circle.fill"
            )
        }
    }

    static func outcomeContext(
        _ outcome: PullRequestMergeOutcome,
        preflight: PullRequestMergePreflight
    ) -> String? {
        let format: String
        switch outcome {
        case .merged:
            format = String(
                localized: "pullRequest.merge.result.merged.context.format",
                defaultValue: "PR #%lld was merged into %@.",
                bundle: .module
            )
        case .approvedButNotMerged(reason: .pullRequestClosed):
            format = String(
                localized: "pullRequest.merge.result.closed.context.format",
                defaultValue: "PR #%lld is no longer open against %@.",
                bundle: .module
            )
        case .approvedButNotMerged(reason: .providerRejected), .outcomeUnknown:
            return nil
        case .approvedButNotMerged:
            format = String(
                localized: "pullRequest.merge.result.notMerged.context.format",
                defaultValue: "PR #%lld was not merged into %@.",
                bundle: .module
            )
        }
        return String(
            format: format,
            Int64(preflight.target.pullRequestID),
            preflight.target.destinationBranch
        )
    }

    static func error(_ error: PullRequestActionError) -> PullRequestMergeResultDisplay {
        PullRequestMergeResultDisplay(
            kind: error == .outcomeUnknown ? .unknown : .failed,
            title: errorTitle(error),
            message: errorMessage(error),
            symbolName: error == .outcomeUnknown ? "questionmark.circle.fill" : "xmark.octagon.fill"
        )
    }

    private static func approvedButNotMergedMessage(
        _ reason: PullRequestApprovedButNotMergedReason
    ) -> String {
        switch reason {
        case .mergeChecksPending:
            String(localized: "The pull request was approved, but required merge checks are still pending.", bundle: .module)
        case .mergeConflict:
            String(localized: "The pull request was approved, but Bitbucket reported a merge conflict.", bundle: .module)
        case .independentApprovalRequired:
            String(localized: "The pull request was approved, but an independent approval is still required.", bundle: .module)
        case .branchRestriction:
            String(localized: "The pull request was approved, but a branch restriction prevented the merge.", bundle: .module)
        case .pullRequestClosed:
            String(localized: "The pull request was approved, but it is no longer open.", bundle: .module)
        case .sourceHeadChanged:
            String(localized: "The pull request was approved, but its source commit changed before the merge.", bundle: .module)
        case .pipelineNotSuccessful:
            String(localized: "The pull request was approved, but its pipeline is no longer successful.", bundle: .module)
        case .validationUnavailable:
            String(localized: "The pull request was approved, but Build Beacon could not complete the second validation, so no merge was attempted.", bundle: .module)
        case .providerRejected:
            String(localized: "The pull request was approved, but Bitbucket rejected the merge.", bundle: .module)
        }
    }

    private static func errorTitle(_ error: PullRequestActionError) -> String {
        switch error {
        case .mergeChecksPending, .mergeConflict, .independentApprovalRequired, .branchRestriction:
            String(localized: "Merge blocked", bundle: .module)
        case .outcomeUnknown:
            String(localized: "Merge outcome unknown", bundle: .module)
        case .notConfigured, .invalidCredentials, .insufficientPermissions:
            String(localized: "Pull request actions unavailable", bundle: .module)
        default:
            String(localized: "Could not approve and merge", bundle: .module)
        }
    }

    private static func errorMessage(_ error: PullRequestActionError) -> String {
        switch error {
        case .notConfigured:
            return String(localized: "Configure a separate pull request actions token in Settings.", bundle: .module)
        case .accountMismatch:
            return String(localized: "The actions token belongs to a different Bitbucket account.", bundle: .module)
        case .invalidTarget:
            return String(localized: "The selected pipeline no longer identifies a valid pull request action.", bundle: .module)
        case .staleRun:
            return String(localized: "A newer pipeline run replaced the build shown in the confirmation.", bundle: .module)
        case .pullRequestNotOpen:
            return String(localized: "The pull request is no longer open.", bundle: .module)
        case .sourceHeadChanged:
            return String(localized: "The pull request source commit changed. Refresh before trying again.", bundle: .module)
        case .pipelineNotSuccessful:
            return String(localized: "The pull request pipeline is no longer successful.", bundle: .module)
        case .approvalRejected:
            return String(localized: "Bitbucket rejected the approval. The pull request was not merged.", bundle: .module)
        case .mergeChecksPending:
            return String(localized: "Required merge checks are still pending.", bundle: .module)
        case .mergeConflict:
            return String(localized: "Bitbucket reported a merge conflict.", bundle: .module)
        case .independentApprovalRequired:
            return String(localized: "An independent approval is required before this pull request can be merged.", bundle: .module)
        case .branchRestriction:
            return String(localized: "A branch restriction prevents this merge.", bundle: .module)
        case .invalidCredentials:
            return String(localized: "The pull request actions token is no longer valid.", bundle: .module)
        case .insufficientPermissions:
            return String(
                localized: "The actions token requires these exact scopes: read:user:bitbucket, read:pullrequest:bitbucket, and write:pullrequest:bitbucket.",
                bundle: .module
            )
        case let .rateLimited(retryAt):
            if let retryAt {
                let format = String(
                    localized: "pullRequest.merge.rateLimited.until.format",
                    defaultValue: "Bitbucket rate limited this action until %@.",
                    bundle: .module
                )
                return String(format: format, retryAt.formatted(date: .omitted, time: .shortened))
            }
            return String(localized: "Bitbucket rate limited this action. Try again later.", bundle: .module)
        case .offline:
            return String(localized: "The Mac is offline. No merge was attempted.", bundle: .module)
        case .timedOut:
            return String(localized: "The request timed out. Review the pull request in Bitbucket before trying again.", bundle: .module)
        case .temporarilyUnavailable:
            return String(localized: "Bitbucket is temporarily unavailable. Try again later.", bundle: .module)
        case .malformedResponse:
            return String(localized: "Bitbucket returned an unsupported response. No result was assumed.", bundle: .module)
        case .cancelled:
            return String(localized: "The pull request action was cancelled before completion.", bundle: .module)
        case .outcomeUnknown:
            return String(localized: "Build Beacon could not confirm the final state. Review the pull request in Bitbucket before trying again.", bundle: .module)
        }
    }
}
