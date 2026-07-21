import XCTest
@testable import BuildBeaconKit

final class PollingPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testRunningAndQueuedUseAtMostThirtySeconds() {
        for phase in [PipelinePhase.running, .queued] {
            let deadline = PollingPolicy.deadline(
                for: observation(phase: phase),
                now: now,
                configuredInterval: 300
            )
            XCTAssertEqual(deadline, now.addingTimeInterval(30))
        }
    }

    func testActivePollingRespectsShorterConfiguredInterval() {
        let deadline = PollingPolicy.deadline(
            for: observation(phase: .running),
            now: now,
            configuredInterval: 30
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(30))
    }

    func testApprovalUsesAtLeastTwoMinutes() {
        let deadline = PollingPolicy.deadline(
            for: observation(phase: .awaitingApproval),
            now: now,
            configuredInterval: 60
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(120))
    }

    func testTerminalAndMissingRunsUseConfiguredNormalInterval() {
        let terminal = PollingPolicy.deadline(
            for: observation(phase: .failed),
            now: now,
            configuredInterval: 180
        )
        let missing = PollingPolicy.deadline(
            for: observation(phase: nil),
            now: now,
            configuredInterval: 180
        )
        XCTAssertEqual(terminal, now.addingTimeInterval(180))
        XCTAssertEqual(missing, now.addingTimeInterval(180))
    }

    func testTransientFailureUsesCappedExponentialBackoff() {
        let failed = observation(phase: .running, failure: .offline)
        XCTAssertEqual(
            PollingPolicy.deadline(for: failed, now: now, configuredInterval: 60, retryAttempt: 1),
            now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            PollingPolicy.deadline(for: failed, now: now, configuredInterval: 60, retryAttempt: 2),
            now.addingTimeInterval(60)
        )
        XCTAssertEqual(PollingPolicy.backoffDelay(attempt: 20), 900)
    }

    func testRateLimitUsesServerDeadlineOrDeterministicFallback() {
        let serverDeadline = now.addingTimeInterval(400)
        XCTAssertEqual(
            PollingPolicy.rateLimitDeadline(for: .rateLimited(retryAt: serverDeadline), now: now, attempt: 1),
            serverDeadline
        )
        XCTAssertEqual(
            PollingPolicy.rateLimitDeadline(for: .rateLimited(retryAt: nil), now: now, attempt: 1),
            now.addingTimeInterval(60)
        )
    }

    private func observation(
        phase: PipelinePhase?,
        failure: ObservationFailure? = nil
    ) -> MonitorObservation {
        let monitor = MonitorConfiguration(
            id: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: "repository"),
                target: .defaultBranch
            ),
            workspaceSlug: "workspace",
            workspaceName: "Workspace",
            repositorySlug: "repository",
            repositoryName: "Repository"
        )
        let run = phase.map {
            PipelineRun(id: PipelineRunID(rawValue: "run"), buildNumber: 1, phase: $0)
        }
        return MonitorObservation(monitor: monitor, lastKnownRun: run, currentFailure: failure)
    }
}
