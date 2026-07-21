import XCTest
@testable import BuildBeaconKit

final class DomainRulesTests: XCTestCase {
    func testOnlyExplicitSuccessIsHealthy() {
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: "COMPLETED", remoteResult: "SUCCESSFUL"), .succeeded)
        XCTAssertEqual(
            PipelineStateReducer.reduce(remoteState: "COMPLETED", remoteResult: nil),
            .unknown(remoteState: "COMPLETED", remoteResult: nil)
        )
        XCTAssertEqual(
            PipelineStateReducer.reduce(remoteState: "mystery", remoteResult: "maybe"),
            .unknown(remoteState: "mystery", remoteResult: "maybe")
        )
    }

    func testRemoteResultsAndActiveStatesRemainDistinct() {
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: nil, remoteResult: "FAILED"), .failed)
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: nil, remoteResult: "ERROR"), .errored)
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: nil, remoteResult: "EXPIRED"), .expired)
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: "IN_PROGRESS", remoteResult: nil), .running)
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: "PAUSED", remoteResult: nil), .awaitingApproval)
        XCTAssertEqual(PipelineStateReducer.reduce(remoteState: "HALTED", remoteResult: nil), .awaitingApproval)
    }

    func testFreshnessThresholdHasFloorAndCeiling() {
        XCTAssertEqual(FreshnessPolicy.threshold(refreshIntervalSeconds: 30), 120)
        XCTAssertEqual(FreshnessPolicy.threshold(refreshIntervalSeconds: 100), 200)
        XCTAssertEqual(FreshnessPolicy.threshold(refreshIntervalSeconds: 10_000), 900)
    }

    func testAggregationPrecedenceAndFalseGreenProtection() {
        let now = Date(timeIntervalSince1970: 2_000)
        let success = observation("success", phase: .succeeded, successAt: now)
        let approval = observation("approval", phase: .awaitingApproval, successAt: now)
        let stale = observation("stale", phase: .succeeded, successAt: now.addingTimeInterval(-121))
        let failed = observation("failed", phase: .failed, successAt: now)

        XCTAssertEqual(aggregate([success], now: now), .healthy)
        XCTAssertEqual(aggregate([success, approval], now: now), .awaitingApproval)
        XCTAssertEqual(aggregate([success, approval, stale], now: now), .stale)
        XCTAssertEqual(aggregate([success, approval, stale, failed], now: now), .attentionRequired)
        XCTAssertEqual(aggregate([observation("unknown", phase: .unknown(remoteState: nil, remoteResult: nil), successAt: now)], now: now), .attentionRequired)
        XCTAssertEqual(aggregate([observation("none", phase: nil, successAt: now)], now: now), .unavailable)
    }

    func testFailureWithBaselineIsStaleButWithoutBaselineIsUnavailable() {
        let now = Date(timeIntervalSince1970: 2_000)
        let withBaseline = observation("old", phase: .succeeded, successAt: now, failure: .offline)
        let withoutBaseline = observation("new", phase: nil, successAt: nil, failure: .offline)
        XCTAssertEqual(aggregate([withBaseline], now: now), .stale)
        XCTAssertEqual(aggregate([withoutBaseline], now: now), .unavailable)
    }

    private func aggregate(_ observations: [MonitorObservation], now: Date) -> AggregateState {
        AggregateStateReducer.reduce(
            isConnected: true,
            observations: Dictionary(uniqueKeysWithValues: observations.map { ($0.monitor.id, $0) }),
            now: now,
            refreshIntervalSeconds: 60
        )
    }

    private func observation(
        _ suffix: String,
        phase: PipelinePhase?,
        successAt: Date?,
        failure: ObservationFailure? = nil
    ) -> MonitorObservation {
        let accountID = AccountID(rawValue: "account")
        let id = MonitorID(
            accountID: accountID,
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: suffix),
            target: .defaultBranch
        )
        let monitor = MonitorConfiguration(
            id: id,
            workspaceSlug: "workspace",
            workspaceName: "Workspace",
            repositorySlug: suffix,
            repositoryName: suffix
        )
        let run = phase.map {
            PipelineRun(id: PipelineRunID(rawValue: "run-\(suffix)"), buildNumber: 1, phase: $0)
        }
        return MonitorObservation(
            monitor: monitor,
            lastKnownRun: run,
            attemptedAt: successAt,
            lastSuccessfulObservationAt: successAt,
            currentFailure: failure
        )
    }
}
