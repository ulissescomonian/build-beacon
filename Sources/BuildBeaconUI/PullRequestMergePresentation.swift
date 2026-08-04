import BuildBeaconKit
import Foundation

public struct PullRequestMergeReadinessDisplay: Equatable {
    let target: PullRequestActionTarget?
    let pullRequestID: Int?
    let badgeTitle: String?
    let detail: String?
    let accessibilityLabel: String?
    let action: PullRequestMergeReadinessAction?

    var isReady: Bool { target != nil }
    var hasAction: Bool { action != nil }
}

/// The explicit next step for a succeeded, open pull request at its current
/// source HEAD. This is presentation-only: only `approveAndMerge` may start
/// the separate confirmed action flow.
enum PullRequestMergeReadinessAction: CaseIterable, Equatable {
    case approveAndMerge
    case enableAndReview
    case configureActions
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
        switch PullRequestMergeCandidateEvaluator.evaluate(observation) {
        case let .eligible(target):
            let format = String(
                localized: "pullRequest.merge.ready.accessibility.format",
                defaultValue: "Pull request #%lld is ready to merge",
                bundle: .module
            )
            let action: PullRequestMergeReadinessAction
            if !actionsConfigured {
                action = .configureActions
            } else if !observation.monitor.allowsPullRequestActions {
                action = .enableAndReview
            } else {
                action = .approveAndMerge
            }
            return PullRequestMergeReadinessDisplay(
                target: target,
                pullRequestID: target.pullRequestID,
                badgeTitle: String(localized: "Ready to merge", bundle: .module),
                detail: readinessDetail(for: action),
                accessibilityLabel: String(format: format, Int64(target.pullRequestID)),
                action: action
            )
        case .ineligible(reason: .missingPullRequestContext):
            return partialDiscoveryDisplay(for: observation)
        case .ineligible:
            return PullRequestMergeReadinessDisplay(
                target: nil,
                pullRequestID: nil,
                badgeTitle: nil,
                detail: nil,
                accessibilityLabel: nil,
                action: nil
            )
        }
    }

    static func actionTitle(_ action: PullRequestMergeReadinessAction) -> String {
        switch action {
        case .approveAndMerge:
            String(localized: "Approve and merge…", bundle: .module)
        case .enableAndReview:
            String(localized: "Enable and review…", bundle: .module)
        case .configureActions:
            String(localized: "Set up approve and merge…", bundle: .module)
        }
    }

    static func actionSymbolName(_ action: PullRequestMergeReadinessAction) -> String {
        switch action {
        case .approveAndMerge: "arrow.triangle.merge"
        case .enableAndReview: "checklist"
        case .configureActions: "gearshape"
        }
    }

    static func actionHelp(_ action: PullRequestMergeReadinessAction) -> String {
        switch action {
        case .approveAndMerge:
            String(localized: "Review and confirm this pull request action", bundle: .module)
        case .enableAndReview:
            String(localized: "Enable pull request actions for this monitor", bundle: .module)
        case .configureActions:
            String(localized: "Configure Pull Request Actions in Settings", bundle: .module)
        }
    }

    static func actionAccessibilityHint(_ action: PullRequestMergeReadinessAction) -> String {
        switch action {
        case .approveAndMerge:
            String(localized: "Opens a confirmation. Nothing is merged until you confirm.", bundle: .module)
        case .enableAndReview:
            String(localized: "Enables pull request actions for this monitor. You can then review and confirm.", bundle: .module)
        case .configureActions:
            String(localized: "Opens Settings so you can configure Pull Request Actions.", bundle: .module)
        }
    }

    static func actionAccessibilityLabel(
        action: PullRequestMergeReadinessAction,
        pullRequestID: Int?,
        repositoryName: String
    ) -> String {
        switch action {
        case .approveAndMerge:
            if let pullRequestID {
                let format = String(
                    localized: "pullRequest.merge.action.accessibility.format",
                    defaultValue: "Approve and merge pull request #%lld for %@",
                    bundle: .module
                )
                return String(format: format, Int64(pullRequestID), repositoryName)
            }
            return String(localized: "Approve and merge pull request", bundle: .module)
        case .enableAndReview:
            let format = String(
                localized: "pullRequest.merge.enable.accessibility.format",
                defaultValue: "Enable pull request actions for %@",
                bundle: .module
            )
            return String(format: format, repositoryName)
        case .configureActions:
            let format = String(
                localized: "pullRequest.merge.configure.accessibility.format",
                defaultValue: "Configure pull request actions for %@",
                bundle: .module
            )
            return String(format: format, repositoryName)
        }
    }

    static func actionAccessibilityLabel(
        action: PullRequestMergeReadinessAction,
        target: PullRequestActionTarget,
        repositoryName: String
    ) -> String {
        actionAccessibilityLabel(
            action: action,
            pullRequestID: target.pullRequestID,
            repositoryName: repositoryName
        )
    }

    static func actionAccessibilityLabel(target: PullRequestActionTarget, repositoryName: String) -> String {
        actionAccessibilityLabel(
            action: .approveAndMerge,
            pullRequestID: target.pullRequestID,
            repositoryName: repositoryName
        )
    }

    private static func partialDiscoveryDisplay(
        for observation: MonitorObservation
    ) -> PullRequestMergeReadinessDisplay {
        guard let run = observation.lastKnownRun,
              run.phase == .succeeded,
              case let .pullRequest(id, _, _) = run.origin,
              let id,
              id > 0 else {
            return PullRequestMergeReadinessDisplay(
                target: nil,
                pullRequestID: nil,
                badgeTitle: nil,
                detail: nil,
                accessibilityLabel: nil,
                action: nil
            )
        }
        return PullRequestMergeReadinessDisplay(
            target: nil,
            pullRequestID: id,
            badgeTitle: nil,
            detail: String(localized: "Configure Pull Request Actions in Settings to identify this pull request before approving and merging.", bundle: .module),
            accessibilityLabel: nil,
            action: .configureActions
        )
    }

    private static func readinessDetail(for action: PullRequestMergeReadinessAction) -> String {
        switch action {
        case .approveAndMerge:
            String(localized: "All merge prerequisites are available.", bundle: .module)
        case .enableAndReview:
            String(localized: "Enable pull request actions for this monitor to review and approve and merge.", bundle: .module)
        case .configureActions:
            String(localized: "Configure Pull Request Actions in Settings to approve and merge.", bundle: .module)
        }
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
