import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

final class PullRequestMergePresentationTests: XCTestCase {
    func testSuccessfulOpenPullRequestIsReadyToMerge() throws {
        let display = PullRequestMergePresentation.readiness(for: observation())

        XCTAssertTrue(display.isReady)
        XCTAssertEqual(display.target?.pullRequestID, 45)
        XCTAssertEqual(display.badgeTitle, String(localized: "Ready to merge", bundle: .module))
        XCTAssertTrue(display.accessibilityLabel?.contains("45") == true)
        XCTAssertEqual(display.action, .approveAndMerge)
    }

    func testAwaitingPipelineApprovalNeverAppearsReadyToMerge() {
        let display = PullRequestMergePresentation.readiness(for: observation(phase: .awaitingApproval))

        XCTAssertFalse(display.isReady)
        XCTAssertNil(display.badgeTitle)
    }

    func testDisabledMonitorIsReadyAndOffersEnableAndReview() throws {
        let display = PullRequestMergePresentation.readiness(for: observation(actionsAllowed: false))

        XCTAssertTrue(display.isReady)
        XCTAssertEqual(display.target?.pullRequestID, 45)
        XCTAssertEqual(display.action, .enableAndReview)
        XCTAssertEqual(
            PullRequestMergePresentation.actionTitle(try XCTUnwrap(display.action)),
            String(localized: "Enable and review…", bundle: .module)
        )
    }

    func testMissingActionsCredentialIsReadyAndOffersConfiguration() throws {
        let display = PullRequestMergePresentation.readiness(
            for: observation(),
            actionsConfigured: false
        )

        XCTAssertTrue(display.isReady)
        XCTAssertEqual(display.target?.pullRequestID, 45)
        XCTAssertEqual(display.action, .configureActions)
        XCTAssertEqual(
            PullRequestMergePresentation.actionTitle(try XCTUnwrap(display.action)),
            String(localized: "Set up approve and merge…", bundle: .module)
        )
    }

    func testSuccessfulPullRequestWithDurationAndMissingActionModeKeepsMetadataAndConfigurationAction() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let completedAt = startedAt.addingTimeInterval(238)
        let observation = observation(startedAt: startedAt, completedAt: completedAt)

        let summary = DashboardRunSummaryPresentation.display(for: observation.lastKnownRun)
        let readiness = PullRequestMergePresentation.readiness(
            for: observation,
            actionsConfigured: false
        )

        XCTAssertNotNil(summary.duration)
        XCTAssertEqual(summary.metadata, summary.duration)
        XCTAssertTrue(readiness.isReady)
        XCTAssertTrue(readiness.hasAction)
        XCTAssertEqual(readiness.action, .configureActions)
    }

    func testIneligiblePullRequestHasNoBadgeTargetOrAction() {
        let display = PullRequestMergePresentation.readiness(for: observation(phase: .failed))

        XCTAssertFalse(display.isReady)
        XCTAssertFalse(display.hasAction)
        XCTAssertNil(display.target)
        XCTAssertNil(display.pullRequestID)
        XCTAssertNil(display.badgeTitle)
        XCTAssertNil(display.action)
    }

    func testMissingPullRequestContextOffersSetupWithoutReadiness() {
        let display = PullRequestMergePresentation.readiness(for: observation(pullRequest: nil))

        XCTAssertFalse(display.isReady)
        XCTAssertTrue(display.hasAction)
        XCTAssertNil(display.target)
        XCTAssertEqual(display.pullRequestID, 45)
        XCTAssertNil(display.badgeTitle)
        XCTAssertEqual(display.action, .configureActions)
    }

    func testSuccessfulNonPullRequestStillOffersNoAction() {
        let display = PullRequestMergePresentation.readiness(for: observation(origin: .branch(name: "develop")))

        XCTAssertFalse(display.isReady)
        XCTAssertFalse(display.hasAction)
        XCTAssertNil(display.pullRequestID)
        XCTAssertNil(display.action)
    }

    func testEachReadyActionProvidesAnAccessibleNextStep() throws {
        let target = try XCTUnwrap(PullRequestMergePresentation.readiness(for: observation()).target)

        for action in PullRequestMergeReadinessAction.allCases {
            XCTAssertFalse(PullRequestMergePresentation.actionTitle(action).isEmpty)
            XCTAssertFalse(PullRequestMergePresentation.actionSymbolName(action).isEmpty)
            XCTAssertFalse(PullRequestMergePresentation.actionHelp(action).isEmpty)
            XCTAssertFalse(PullRequestMergePresentation.actionAccessibilityHint(action).isEmpty)
            XCTAssertFalse(
                PullRequestMergePresentation.actionAccessibilityLabel(
                    action: action,
                    pullRequestID: target.pullRequestID,
                    repositoryName: "bladecp hub"
                ).isEmpty
            )
        }
    }

    func testConfirmationIncludesIdentityAndDestinationAsOneLocalizedSentence() {
        let preflight = preflight()
        let message = PullRequestMergePresentation.confirmationMessage(
            preflight: preflight,
            accountName: "Ulisses"
        )

        XCTAssertTrue(message.contains("45"))
        XCTAssertTrue(message.contains("Ulisses"))
        XCTAssertTrue(message.contains("develop"))
    }

    func testAllMergeStrategiesHaveDistinctTitles() {
        let titles = Set(PullRequestMergeStrategy.allCases.map(PullRequestMergePresentation.strategyTitle))
        XCTAssertEqual(titles.count, PullRequestMergeStrategy.allCases.count)
        XCTAssertFalse(titles.contains(""))
    }

    func testOperationProgressCoversApproveMergeAndVerification() {
        XCTAssertNotEqual(
            PullRequestMergePresentation.operationTitle(.approving),
            PullRequestMergePresentation.operationTitle(.merging)
        )
        XCTAssertNotEqual(
            PullRequestMergePresentation.operationTitle(.merging),
            PullRequestMergePresentation.operationTitle(.waitingForProvider)
        )
    }

    func testMergedApprovedButNotMergedAndUnknownStayDistinct() {
        let merged = PullRequestMergePresentation.outcome(.merged(mergeCommitHash: "abcdef1234567890"))
        let blocked = PullRequestMergePresentation.outcome(
            .approvedButNotMerged(reason: .independentApprovalRequired)
        )
        let unknown = PullRequestMergePresentation.outcome(.outcomeUnknown)

        XCTAssertEqual(merged.kind, .merged)
        XCTAssertEqual(blocked.kind, .approvedButNotMerged)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertTrue(merged.message.contains("abcdef123456"))
        XCTAssertNotEqual(merged.title, blocked.title)
        XCTAssertNotEqual(blocked.title, unknown.title)
    }

    func testBlockedAndUnknownErrorsUseHonestMessages() {
        let blocked = PullRequestMergePresentation.error(.mergeConflict)
        let unknown = PullRequestMergePresentation.error(.outcomeUnknown)

        XCTAssertEqual(blocked.kind, .failed)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertNotEqual(blocked.title, unknown.title)
        XCTAssertTrue(unknown.message.localizedCaseInsensitiveContains("Bitbucket"))
    }

    func testInsufficientPermissionsNamesEveryRequiredScope() {
        let message = PullRequestMergePresentation.error(.insufficientPermissions).message

        XCTAssertTrue(message.contains("read:user:bitbucket"))
        XCTAssertTrue(message.contains("read:pullrequest:bitbucket"))
        XCTAssertTrue(message.contains("write:pullrequest:bitbucket"))
    }

    func testApprovedButNotMergedContextDoesNotClaimEveryPullRequestRemainsOpen() throws {
        let preflight = preflight()
        let closed = try XCTUnwrap(
            PullRequestMergePresentation.outcomeContext(
                .approvedButNotMerged(reason: .pullRequestClosed),
                preflight: preflight
            )
        )
        let blocked = try XCTUnwrap(
            PullRequestMergePresentation.outcomeContext(
                .approvedButNotMerged(reason: .mergeChecksPending),
                preflight: preflight
            )
        )
        let rejected = PullRequestMergePresentation.outcomeContext(
            .approvedButNotMerged(reason: .providerRejected),
            preflight: preflight
        )
        let closedFormat = String(
            localized: "pullRequest.merge.result.closed.context.format",
            bundle: .module
        )
        let notMergedFormat = String(
            localized: "pullRequest.merge.result.notMerged.context.format",
            bundle: .module
        )

        XCTAssertEqual(closed, String(format: closedFormat, Int64(45), "develop"))
        XCTAssertEqual(blocked, String(format: notMergedFormat, Int64(45), "develop"))
        XCTAssertNotEqual(closed, blocked)
        XCTAssertNil(rejected)
    }

    func testMergeStringsExistInEnglishAndBrazilianPortuguese() throws {
        let keys = [
            "Ready to Merge",
            "Ready to merge",
            "%lld pull requests ready to merge",
            "Approve and merge…",
            "Enable and review…",
            "Set up approve and merge…",
            "Review and confirm this pull request action",
            "Enable pull request actions for this monitor",
            "Configure Pull Request Actions in Settings",
            "Enables pull request actions for this monitor. You can then review and confirm.",
            "Opens Settings so you can configure Pull Request Actions.",
            "Enable pull request actions for this monitor to review and approve and merge.",
            "Configure Pull Request Actions in Settings to approve and merge.",
            "Approve and merge pull request",
            "Configure Pull Request Actions in Settings to identify this pull request before approving and merging.",
            "pullRequest.merge.ready.accessibility.format",
            "pullRequest.merge.action.accessibility.format",
            "pullRequest.merge.enable.accessibility.format",
            "pullRequest.merge.configure.accessibility.format",
            "pullRequest.merge.confirmation.message.format",
            "pullRequest.merge.success.commit.format",
            "pullRequest.merge.execution.detail.format",
            "pullRequest.merge.result.merged.context.format",
            "pullRequest.merge.result.closed.context.format",
            "pullRequest.merge.result.notMerged.context.format",
            "All merge prerequisites are available.",
            "Approve and merge pull request?",
            "Production merge",
            "Merge strategy",
            "Merge commit",
            "Squash",
            "Fast-forward",
            "Approving pull request…",
            "Merging pull request…",
            "Verifying merge with Bitbucket…",
            "Pull request merged",
            "Approved, but not merged",
            "Merge outcome unknown",
            "Pull Request Actions",
            "Use a separate Bitbucket token with these exact scopes: read:user:bitbucket, read:pullrequest:bitbucket, and write:pullrequest:bitbucket. Monitoring keeps using the existing read-only token.",
            "The actions token requires these exact scopes: read:user:bitbucket, read:pullrequest:bitbucket, and write:pullrequest:bitbucket.",
            "Enable Pull Request Actions",
            "PR actions",
        ]

        for localization in ["en", "pt-BR"] {
            let strings = try localizedStrings(for: localization)
            for key in keys {
                XCTAssertTrue(strings.contains("\"\(key)\""), "Missing \(key) for \(localization)")
            }
        }
    }

    private func observation(
        phase: PipelinePhase = .succeeded,
        actionsAllowed: Bool = true,
        origin: PipelineRunOrigin = .pullRequest(
            id: 45,
            sourceBranch: "feature",
            destinationBranch: "develop"
        ),
        pullRequest: PipelinePullRequestContext? = PipelinePullRequestContext(
            id: 45,
            title: "Ready",
            state: "OPEN",
            sourceCommitHash: "abcdef1234567890"
        ),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> MonitorObservation {
        let id = MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "repository"),
            target: .repositoryLatest
        )
        let monitor = MonitorConfiguration(
            id: id,
            workspaceSlug: "epicway",
            workspaceName: "Epicway",
            repositorySlug: "bladecp-hub",
            repositoryName: "bladecp hub",
            isProduction: true,
            allowsPullRequestActions: actionsAllowed
        )
        let run = PipelineRun(
            id: PipelineRunID(rawValue: "run"),
            buildNumber: 50,
            phase: phase,
            origin: origin,
            commitHash: "abcdef1234567890",
            startedAt: startedAt,
            completedAt: completedAt,
            pullRequest: pullRequest
        )
        return MonitorObservation(
            monitor: monitor,
            lastKnownRun: run,
            attemptedAt: Date(),
            lastSuccessfulObservationAt: Date()
        )
    }

    private func preflight() -> PullRequestMergePreflight {
        let target = try! XCTUnwrap(PullRequestMergePresentation.readiness(for: observation()).target)
        return PullRequestMergePreflight(
            target: target,
            title: "Ready",
            availableStrategies: [.mergeCommit, .squash],
            defaultStrategy: .mergeCommit,
            closeSourceBranch: false,
            alreadyApproved: false
        )
    }

    private func localizedStrings(for localization: String) throws -> String {
        let path = try XCTUnwrap(
            Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            )
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
