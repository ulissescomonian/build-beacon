import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

final class PipelineDetailPresentationTests: XCTestCase {
    func testApprovalActionAppearsOnlyForAwaitingApprovalBuild() {
        XCTAssertTrue(PipelineDetailPresentation.shouldShowApprovalAction(for: makeRun(phase: .awaitingApproval)))
        XCTAssertFalse(PipelineDetailPresentation.shouldShowApprovalAction(for: makeRun(phase: .running)))
        XCTAssertFalse(
            PipelineDetailPresentation.shouldShowApprovalAction(
                for: makeRun(phase: .awaitingApproval, buildNumber: 0)
            )
        )
    }

    func testDurationUsesCompletedAndStartedDates() {
        let run = makeRun(startedAt: date(0), completedAt: date(90))

        XCTAssertEqual(
            PipelineDetailPresentation.durationText(for: run),
            Duration.seconds(90).formatted(.units())
        )
    }

    func testDurationComparisonDescribesFasterAndSlowerRuns() throws {
        let slower = makeHistoryEntry(id: "new", startedAt: date(0), completedAt: date(120))
        let faster = makeHistoryEntry(id: "old", startedAt: date(0), completedAt: date(60))

        let slowerText = try XCTUnwrap(
            PipelineDetailPresentation.durationComparison(for: slower, previous: faster)
        )
        let fasterText = try XCTUnwrap(
            PipelineDetailPresentation.durationComparison(for: faster, previous: slower)
        )
        let duration = Duration.seconds(60).formatted(.units())
        XCTAssertTrue(slowerText.contains(duration))
        XCTAssertTrue(fasterText.contains(duration))
        XCTAssertNotEqual(slowerText, fasterText)
    }

    func testDurationComparisonOmitsMissingOrEqualDurations() {
        let missing = makeHistoryEntry(completedAt: nil)
        let equal = makeHistoryEntry(id: "equal", startedAt: date(0), completedAt: date(60))
        let previous = makeHistoryEntry(id: "previous", startedAt: date(0), completedAt: date(60))

        XCTAssertNil(PipelineDetailPresentation.durationComparison(for: missing, previous: previous))
        XCTAssertNotNil(PipelineDetailPresentation.durationComparison(for: equal, previous: previous))
    }

    func testTimelinePlacesCurrentRunFirstAndRemovesDuplicateIDs() {
        let current = makeRun(id: "current")
        let duplicate = makeHistoryEntry(id: "current")
        let previous = makeHistoryEntry(id: "previous")

        XCTAssertEqual(
            PipelineDetailPresentation.timeline(
                current: current,
                monitorID: monitorID,
                selectedHistory: [duplicate, previous]
            ).map(\.runID.rawValue),
            ["current", "previous"]
        )
    }

    func testCommitDetailCombinesAuthorAndDateWithoutURL() {
        let context = PipelineCommitContext(
            message: "A useful commit",
            authorName: "Example Author",
            date: date(0)
        )

        XCTAssertTrue(PipelineDetailPresentation.commitDetail(for: context)?.contains("Example Author") == true)
        XCTAssertFalse(PipelineDetailPresentation.commitDetail(for: context)?.contains("http") == true)
    }

    func testDynamicPresentationStringsUseStableLocalizedFallbacks() {
        XCTAssertTrue(PipelineDetailPresentation.buildTitle(42).contains("42"))
        XCTAssertTrue(PipelineDetailPresentation.pullRequestTitle(17).contains("17"))
    }

    func testNotificationBuildCalloutOnlyAppearsForAChangedBuild() {
        XCTAssertTrue(
            PipelineDetailPresentation.shouldShowNotificationBuildCallout(
                notificationBuildNumber: 41,
                currentBuildNumber: 42
            )
        )
        XCTAssertFalse(
            PipelineDetailPresentation.shouldShowNotificationBuildCallout(
                notificationBuildNumber: 42,
                currentBuildNumber: 42
            )
        )
        XCTAssertFalse(
            PipelineDetailPresentation.shouldShowNotificationBuildCallout(
                notificationBuildNumber: nil,
                currentBuildNumber: 42
            )
        )
        XCTAssertTrue(PipelineDetailPresentation.notificationBuildCalloutTitle(41).contains("41"))
    }

    private func makeRun(
        id: String = "run",
        phase: PipelinePhase = .succeeded,
        buildNumber: Int = 12,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> PipelineRun {
        PipelineRun(
            id: PipelineRunID(rawValue: id),
            buildNumber: buildNumber,
            phase: phase,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private var monitorID: MonitorID {
        MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "repository"),
            target: .repositoryLatest
        )
    }

    private func makeHistoryEntry(
        id: String = "run",
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> PipelineHistoryEntry {
        PipelineHistoryEntry(
            monitorID: monitorID,
            runID: PipelineRunID(rawValue: id),
            buildNumber: 12,
            phase: .succeeded,
            startedAt: startedAt,
            completedAt: completedAt,
            observedAt: date(1)
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
