import BuildBeaconKit
@testable import BuildBeacon
import XCTest

@MainActor
final class ProductionRuntimeTests: XCTestCase {
    func testAccountTransitionRunsOnlyAfterPullRequestActionsAreDisconnected() async throws {
        let events = RuntimeEventRecorder()
        let service = PullRequestActionServiceSpy(events: events)

        let result = try await afterDisconnectingPullRequestActions(using: service) {
            await events.record("transition")
            return 42
        }

        XCTAssertEqual(result, 42)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["cleanup", "transition"])
    }

    func testAccountTransitionDoesNotStartWhenPullRequestActionCleanupFails() async {
        let events = RuntimeEventRecorder()
        let service = PullRequestActionServiceSpy(events: events, disconnectFails: true)

        do {
            _ = try await afterDisconnectingPullRequestActions(using: service) {
                await events.record("transition")
            }
            XCTFail("Expected cleanup failure")
        } catch let error as RuntimeTestError {
            XCTAssertEqual(error, .intentional)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["cleanup"])
    }

    func testApproveAndMergeWithProgressForwardsEveryPhaseAndOutcome() async throws {
        let phases: [PullRequestActionOperationPhase] = [
            .revalidatingBeforeApproval,
            .approving,
            .revalidatingBeforeMerge,
            .merging,
            .waitingForProvider,
        ]
        let expectedOutcome = PullRequestMergeOutcome.merged(mergeCommitHash: "merge-commit")
        let events = RuntimeEventRecorder()
        let service = PullRequestActionServiceSpy(
            events: events,
            progressPhases: phases,
            mergeOutcome: expectedOutcome
        )
        let receivedPhases = RuntimePhaseRecorder()
        let preflight = makePreflight()

        let outcome = try await approveAndMergeWithProgress(
            using: service,
            preflight: preflight,
            strategy: .squash
        ) { phase in
            await receivedPhases.record(phase)
        }

        XCTAssertEqual(outcome, expectedOutcome)
        let forwardedPhases = await receivedPhases.values
        let forwardedPreflight = await service.receivedPreflight
        let forwardedStrategy = await service.receivedStrategy
        XCTAssertEqual(forwardedPhases, phases)
        XCTAssertEqual(forwardedPreflight, preflight)
        XCTAssertEqual(forwardedStrategy, .squash)
    }

    private func makePreflight() -> PullRequestMergePreflight {
        let accountID = AccountID(rawValue: "account")
        let monitorID = MonitorID(
            accountID: accountID,
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "repository"),
            target: .branch(exactName: "main")
        )
        let target = PullRequestActionTarget(
            accountID: accountID,
            monitorID: monitorID,
            workspaceSlug: "workspace",
            repositorySlug: "repository",
            pullRequestID: 42,
            runID: PipelineRunID(rawValue: "run"),
            buildNumber: 7,
            expectedSourceCommitHash: "source-commit",
            sourceBranch: "feature",
            destinationBranch: "main",
            isProduction: true
        )
        return PullRequestMergePreflight(
            target: target,
            title: "Production release",
            availableStrategies: [.mergeCommit, .squash],
            defaultStrategy: .mergeCommit,
            closeSourceBranch: true,
            alreadyApproved: false
        )
    }
}

private enum RuntimeTestError: Error, Equatable {
    case intentional
}

private actor RuntimeEventRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor RuntimePhaseRecorder {
    private(set) var values: [PullRequestActionOperationPhase] = []

    func record(_ value: PullRequestActionOperationPhase) {
        values.append(value)
    }
}

private actor PullRequestActionServiceSpy: PullRequestActionServicing {
    private let events: RuntimeEventRecorder
    private let disconnectFails: Bool
    private let progressPhases: [PullRequestActionOperationPhase]
    private let mergeOutcome: PullRequestMergeOutcome
    private(set) var receivedPreflight: PullRequestMergePreflight?
    private(set) var receivedStrategy: PullRequestMergeStrategy?

    init(
        events: RuntimeEventRecorder,
        disconnectFails: Bool = false,
        progressPhases: [PullRequestActionOperationPhase] = [],
        mergeOutcome: PullRequestMergeOutcome = .outcomeUnknown
    ) {
        self.events = events
        self.disconnectFails = disconnectFails
        self.progressPhases = progressPhases
        self.mergeOutcome = mergeOutcome
    }

    var isConfigured: Bool { true }

    func configure(_ credential: AccountCredential, expectedAccountID: AccountID) async throws {}

    func disconnectPullRequestActions() async throws {
        await events.record("cleanup")
        if disconnectFails { throw RuntimeTestError.intentional }
    }

    func preflight(_ target: PullRequestActionTarget) async throws -> PullRequestMergePreflight {
        throw PullRequestActionError.notConfigured
    }

    func approveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy
    ) async throws -> PullRequestMergeOutcome {
        throw PullRequestActionError.notConfigured
    }

    func approveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy,
        progress: @escaping @Sendable (PullRequestActionOperationPhase) async -> Void
    ) async throws -> PullRequestMergeOutcome {
        receivedPreflight = preflight
        receivedStrategy = strategy
        for phase in progressPhases {
            await progress(phase)
        }
        return mergeOutcome
    }
}
