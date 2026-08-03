import BuildBeaconKit
import XCTest

final class PullRequestMergeEligibilityTests: XCTestCase {
    func testEligibleRequiresOpenNonDraftPRAndSuccessfulPipelineAtSourceHead() throws {
        let observation = makeObservation()

        let eligibility = PullRequestMergeEligibilityEvaluator.evaluate(observation)

        guard case let .eligible(target) = eligibility else {
            return XCTFail("Expected eligible target")
        }
        XCTAssertEqual(target.pullRequestID, 42)
        XCTAssertEqual(target.runID, PipelineRunID(rawValue: "run"))
        XCTAssertEqual(target.expectedSourceCommitHash, "abc123")
        XCTAssertTrue(target.isProduction)
    }

    func testSourceHeadMismatchFailsClosed() {
        let observation = makeObservation(sourceCommitHash: "new-head")

        XCTAssertEqual(
            PullRequestMergeEligibilityEvaluator.evaluate(observation),
            .ineligible(reason: .sourceHeadChanged)
        )
    }

    func testObservationFailureAndDisabledMonitorNeverBecomeEligible() {
        var disabledMonitor = makeMonitor()
        disabledMonitor.allowsPullRequestActions = false
        let disabled = makeObservation(monitor: disabledMonitor)
        let unavailable = MonitorObservation(
            monitor: makeMonitor(),
            lastKnownRun: makeObservation().lastKnownRun,
            currentFailure: .offline
        )

        XCTAssertEqual(
            PullRequestMergeEligibilityEvaluator.evaluate(disabled),
            .ineligible(reason: .actionsDisabled)
        )
        XCTAssertEqual(
            PullRequestMergeEligibilityEvaluator.evaluate(unavailable),
            .ineligible(reason: .staleObservation)
        )
    }

    private func makeObservation(
        monitor: MonitorConfiguration? = nil,
        sourceCommitHash: String = "abc123"
    ) -> MonitorObservation {
        MonitorObservation(
            monitor: monitor ?? makeMonitor(),
            lastKnownRun: PipelineRun(
                id: PipelineRunID(rawValue: "run"),
                buildNumber: 12,
                phase: .succeeded,
                origin: .pullRequest(
                    id: 42,
                    sourceBranch: "feature/actions",
                    destinationBranch: "main"
                ),
                commitHash: "abc123",
                pullRequest: PipelinePullRequestContext(
                    id: 42,
                    title: "Actions",
                    state: "OPEN",
                    sourceCommitHash: sourceCommitHash,
                    isDraft: false
                )
            )
        )
    }

    private func makeMonitor() -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: "repository"),
                target: .repositoryLatest
            ),
            workspaceSlug: "workspace",
            workspaceName: "Workspace",
            repositorySlug: "repository",
            repositoryName: "Repository",
            isProduction: true,
            allowsPullRequestActions: true
        )
    }
}
