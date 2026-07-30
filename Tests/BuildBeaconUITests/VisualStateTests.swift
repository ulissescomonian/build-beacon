import BuildBeaconKit
@testable import BuildBeaconUI
import SwiftUI
import XCTest

final class VisualStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 123_456)

    func testFreshSuccessfulObservationWithoutRunShowsNoPipelineRun() {
        let state = observation(lastKnownRun: nil).visualState(
            refreshIntervalSeconds: 60,
            now: now
        )

        XCTAssertEqual(state.symbolName, "tray")
        XCTAssertEqual(state.title, "No Pipeline Run")
        XCTAssertEqual(state.tint, .secondary)
    }

    func testUnknownPipelineRunContinuesToShowUnknown() {
        let run = PipelineRun(
            id: PipelineRunID(rawValue: "run"),
            buildNumber: 1,
            phase: .unknown(remoteState: "MYSTERY", remoteResult: nil)
        )
        let state = observation(lastKnownRun: run).visualState(
            refreshIntervalSeconds: 60,
            now: now
        )

        XCTAssertEqual(state.symbolName, "questionmark.circle")
        XCTAssertEqual(state.title, "Unknown")
        XCTAssertEqual(state.tint, .secondary)
    }

    func testAwaitingApprovalPipelineRunHasDistinctVisualState() {
        let run = PipelineRun(
            id: PipelineRunID(rawValue: "run"),
            buildNumber: 1,
            phase: .awaitingApproval
        )

        let state = observation(lastKnownRun: run).visualState(
            refreshIntervalSeconds: 60,
            now: now
        )

        XCTAssertEqual(state.symbolName, "pause.circle.fill")
        XCTAssertEqual(state.title, "Awaiting approval")
        XCTAssertEqual(state.tint, .blue)
    }

    func testFailureWithoutRunContinuesToShowFailure() {
        let state = observation(lastKnownRun: nil, currentFailure: .offline).visualState(
            refreshIntervalSeconds: 60,
            now: now
        )

        XCTAssertEqual(state.symbolName, "wifi.exclamationmark")
        XCTAssertEqual(state.title, "Offline · showing last known result")
        XCTAssertEqual(state.tint, .secondary)
    }

    private func observation(
        lastKnownRun: PipelineRun?,
        currentFailure: ObservationFailure? = nil
    ) -> MonitorObservation {
        let monitor = MonitorConfiguration(
            id: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: "repository"),
                target: .repositoryLatest
            ),
            workspaceSlug: "workspace",
            workspaceName: "Workspace",
            repositorySlug: "repository",
            repositoryName: "Repository"
        )
        return MonitorObservation(
            monitor: monitor,
            lastKnownRun: lastKnownRun,
            attemptedAt: now,
            lastSuccessfulObservationAt: now,
            currentFailure: currentFailure
        )
    }
}
