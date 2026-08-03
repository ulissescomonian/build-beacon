import BuildBeaconKit
import Foundation
import XCTest

final class ApprovalWaitStateReducerTests: XCTestCase {
    func testFirstDetectionIsStableAcrossRefreshAndClearsAfterResolution() {
        let monitor = makeMonitor()
        let first = date(10)
        let initial = ApprovalWaitStateReducer.reduce(
            markers: [],
            observations: [monitor.id: observation(monitor, run: "1", phase: .awaitingApproval)],
            activeMonitorIDs: [monitor.id],
            detectedAt: first
        )
        let refreshed = ApprovalWaitStateReducer.reduce(
            markers: initial,
            observations: [monitor.id: observation(monitor, run: "1", phase: .awaitingApproval)],
            activeMonitorIDs: [monitor.id],
            detectedAt: date(40)
        )
        let resolved = ApprovalWaitStateReducer.reduce(
            markers: refreshed,
            observations: [monitor.id: observation(monitor, run: "1", phase: .running)],
            activeMonitorIDs: [monitor.id],
            detectedAt: date(50)
        )

        XCTAssertEqual(refreshed.first?.firstDetectedAt, first)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testNewRunAndRemovedMonitorDiscardOldApprovalButFailureRetainsIt() {
        let monitor = makeMonitor()
        let existing = ApprovalWaitMarker(monitorID: monitor.id, runID: PipelineRunID(rawValue: "old"), firstDetectedAt: date(1))
        let retainedOnFailure = ApprovalWaitStateReducer.reduce(
            markers: [existing],
            observations: [monitor.id: unavailableObservation(monitor)],
            activeMonitorIDs: [monitor.id],
            detectedAt: date(2)
        )
        let advanced = ApprovalWaitStateReducer.reduce(
            markers: retainedOnFailure,
            observations: [monitor.id: observation(monitor, run: "new", phase: .awaitingApproval)],
            activeMonitorIDs: [monitor.id],
            detectedAt: date(3)
        )
        let removed = ApprovalWaitStateReducer.reduce(
            markers: advanced,
            observations: [:],
            activeMonitorIDs: [],
            detectedAt: date(4)
        )

        XCTAssertEqual(retainedOnFailure, [existing])
        XCTAssertEqual(advanced.map(\.runID), [PipelineRunID(rawValue: "new")])
        XCTAssertEqual(advanced.first?.firstDetectedAt, date(3))
        XCTAssertTrue(removed.isEmpty)
    }

    private func makeMonitor() -> MonitorConfiguration {
        MonitorConfiguration(
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
    }

    private func observation(
        _ monitor: MonitorConfiguration,
        run: String,
        phase: PipelinePhase
    ) -> MonitorObservation {
        MonitorObservation(
            monitor: monitor,
            lastKnownRun: PipelineRun(
                id: PipelineRunID(rawValue: run),
                buildNumber: 1,
                phase: phase
            ),
            attemptedAt: date(0),
            lastSuccessfulObservationAt: date(0)
        )
    }

    private func unavailableObservation(_ monitor: MonitorConfiguration) -> MonitorObservation {
        MonitorObservation(
            monitor: monitor,
            lastKnownRun: nil,
            attemptedAt: date(0),
            lastSuccessfulObservationAt: nil,
            currentFailure: .offline
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
