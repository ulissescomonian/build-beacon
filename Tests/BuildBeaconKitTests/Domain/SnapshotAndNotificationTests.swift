import XCTest
@testable import BuildBeaconKit

final class SnapshotAndNotificationTests: XCTestCase {
    func testDiffReportsPresenceContentAndAggregateChanges() {
        let oldA = observation("a", phase: .running, runID: "1")
        let newA = observation("a", phase: .failed, runID: "1")
        let oldB = observation("b", phase: .succeeded, runID: "1")
        let newC = observation("c", phase: .running, runID: "1")
        let old = snapshot([oldA, oldB], aggregate: .running)
        let new = snapshot([newA, newC], aggregate: .attentionRequired)

        let diff = SnapshotDiff(previous: old, current: new)
        XCTAssertEqual(Set(diff.added.keys), [newC.monitor.id])
        XCTAssertEqual(Set(diff.removed.keys), [oldB.monitor.id])
        XCTAssertEqual(diff.changed.map(\.monitorID), [newA.monitor.id])
        XCTAssertTrue(diff.aggregateStateChanged)
    }

    func testInitialBaselineIsSilent() {
        let failed = observation("a", phase: .failed, runID: "1")
        XCTAssertTrue(NotificationPolicy.events(
            previous: nil,
            current: snapshot([failed], aggregate: .attentionRequired),
            configuration: configuration()
        ).isEmpty)
    }

    func testFailureNewFailedRunRecoveryAndApprovalEdges() {
        let running = observation("a", phase: .running, runID: "1")
        let failed = observation("a", phase: .failed, runID: "1")
        XCTAssertEqual(events(from: running, to: failed).map(\.kind), [.failed])

        let anotherFailure = observation("a", phase: .failed, runID: "2")
        XCTAssertEqual(events(from: failed, to: anotherFailure).map(\.kind), [.failed])

        let recovered = observation("a", phase: .succeeded, runID: "2")
        XCTAssertEqual(events(from: anotherFailure, to: recovered).map(\.kind), [.recovered])

        let approval = observation("a", phase: .awaitingApproval, runID: "3")
        XCTAssertEqual(events(from: recovered, to: approval).map(\.kind), [.awaitingApproval])
    }

    func testUnknownIsNeverRecovery() {
        let failed = observation("a", phase: .failed, runID: "1")
        let unknown = observation("a", phase: .unknown(remoteState: "x", remoteResult: nil), runID: "1")
        XCTAssertTrue(events(from: failed, to: unknown).isEmpty)
    }

    func testAuthenticationTransitionNotifiesOnce() {
        let healthy = observation("a", phase: .succeeded, runID: "1")
        let auth = observation("a", phase: .succeeded, runID: "1", failure: .invalidCredentials)
        XCTAssertEqual(events(from: healthy, to: auth).map(\.kind), [.authenticationRequired])
        XCTAssertTrue(events(from: auth, to: auth).isEmpty)
    }

    func testAuthenticationFailureEmitsOnlyOneEventForMultipleMonitors() {
        let oldA = observation("a", phase: .succeeded, runID: "1")
        let oldB = observation("b", phase: .succeeded, runID: "1")
        let authA = observation("a", phase: .succeeded, runID: "1", failure: .invalidCredentials)
        let authB = observation("b", phase: .succeeded, runID: "1", failure: .invalidCredentials)

        let result = NotificationPolicy.events(
            previous: snapshot([oldA, oldB], aggregate: .healthy),
            current: snapshot([authA, authB], aggregate: .attentionRequired),
            configuration: configuration()
        )
        XCTAssertEqual(result.map(\.kind), [.authenticationRequired])
        XCTAssertEqual(result.first?.monitorID, authA.monitor.id)
    }

    func testNotificationEventsCarryTheExactPipelineBuildNumber() {
        let running = observation("a", phase: .running, runID: "1", buildNumber: 11)
        let failed = observation("a", phase: .failed, runID: "2", buildNumber: 12)
        let recovered = observation("a", phase: .succeeded, runID: "2", buildNumber: 12)
        let approval = observation("a", phase: .awaitingApproval, runID: "3", buildNumber: 13)
        let authentication = observation(
            "a",
            phase: .succeeded,
            runID: "3",
            buildNumber: 13,
            failure: .invalidCredentials
        )

        XCTAssertEqual(events(from: running, to: failed).first?.buildNumber, 12)
        XCTAssertEqual(events(from: failed, to: recovered).first?.buildNumber, 12)
        XCTAssertEqual(events(from: recovered, to: approval).first?.buildNumber, 13)
        XCTAssertEqual(events(from: approval, to: authentication).first?.buildNumber, 13)
    }

    func testFavoriteSuccessNotificationsRequireEnabledToggleFavoriteAndNewSuccessfulRun() {
        let old = observation("a", phase: .running, runID: "1", isFavorite: true)
        let succeeded = observation("a", phase: .succeeded, runID: "2", buildNumber: 42, isFavorite: true)

        let enabled = configuration(notifyOnFavoriteSuccess: true)
        let success = NotificationPolicy.events(
            previous: snapshot([old], aggregate: .running),
            current: snapshot([succeeded], aggregate: .healthy),
            configuration: enabled
        )
        XCTAssertEqual(success.map(\.kind), [.succeeded])
        XCTAssertEqual(success.first?.buildNumber, 42)
        XCTAssertEqual(success.first?.title, "Favorite build succeeded")
        XCTAssertEqual(success.first?.body, "a #42 completed successfully.")

        let sameRunSuccess = observation("a", phase: .succeeded, runID: "1", buildNumber: 41, isFavorite: true)
        XCTAssertEqual(NotificationPolicy.events(
            previous: snapshot([old], aggregate: .running),
            current: snapshot([sameRunSuccess], aggregate: .healthy),
            configuration: enabled
        ).map(\.kind), [.succeeded])

        XCTAssertTrue(NotificationPolicy.events(
            previous: snapshot([old], aggregate: .running),
            current: snapshot([succeeded], aggregate: .healthy),
            configuration: configuration(notifyOnFavoriteSuccess: false)
        ).isEmpty)

        let notFavorite = observation("a", phase: .succeeded, runID: "2", isFavorite: false)
        XCTAssertTrue(NotificationPolicy.events(
            previous: snapshot([old], aggregate: .running),
            current: snapshot([notFavorite], aggregate: .healthy),
            configuration: enabled
        ).isEmpty)

        XCTAssertTrue(NotificationPolicy.events(
            previous: snapshot([succeeded], aggregate: .healthy),
            current: snapshot([succeeded], aggregate: .healthy),
            configuration: enabled
        ).isEmpty)
    }

    func testFavoriteSuccessBaselineIsSilentAndRecoveryTakesPrecedence() {
        let favoriteSuccess = observation("a", phase: .succeeded, runID: "2", isFavorite: true)
        let enabled = configuration(notifyOnFavoriteSuccess: true)
        XCTAssertTrue(NotificationPolicy.events(
            previous: nil,
            current: snapshot([favoriteSuccess], aggregate: .healthy),
            configuration: enabled
        ).isEmpty)

        let failed = observation("a", phase: .failed, runID: "1", isFavorite: true)
        XCTAssertEqual(NotificationPolicy.events(
            previous: snapshot([failed], aggregate: .attentionRequired),
            current: snapshot([favoriteSuccess], aggregate: .healthy),
            configuration: enabled
        ).map(\.kind), [.recovered])

        XCTAssertTrue(NotificationPolicy.events(
            previous: snapshot([failed], aggregate: .attentionRequired),
            current: snapshot([favoriteSuccess], aggregate: .healthy),
            configuration: configuration(notifyOnRecovery: false, notifyOnFavoriteSuccess: true)
        ).isEmpty)
    }

    private func events(from old: MonitorObservation, to new: MonitorObservation) -> [NotificationEvent] {
        NotificationPolicy.events(
            previous: snapshot([old], aggregate: .running),
            current: snapshot([new], aggregate: .attentionRequired),
            configuration: configuration()
        )
    }

    private func configuration(
        notifyOnRecovery: Bool = true,
        notifyOnFavoriteSuccess: Bool = false
    ) -> AppConfiguration {
        AppConfiguration(
            account: AccountProfile(id: AccountID(rawValue: "account"), displayName: "A", email: "a@example.com"),
            notifyOnRecovery: notifyOnRecovery,
            notifyOnFavoriteSuccess: notifyOnFavoriteSuccess
        )
    }

    private func snapshot(_ observations: [MonitorObservation], aggregate: AggregateState) -> MonitoringSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return MonitoringSnapshot(
            cycleID: UUID(), startedAt: date, completedAt: date, reason: .manual,
            observations: Dictionary(uniqueKeysWithValues: observations.map { ($0.monitor.id, $0) }),
            aggregateState: aggregate
        )
    }

    private func observation(
        _ repository: String,
        phase: PipelinePhase,
        runID: String,
        buildNumber: Int = 1,
        failure: ObservationFailure? = nil,
        isFavorite: Bool = false
    ) -> MonitorObservation {
        let id = MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: repository),
            target: .defaultBranch
        )
        let monitor = MonitorConfiguration(
            id: id, workspaceSlug: "workspace", workspaceName: "Workspace",
            repositorySlug: repository, repositoryName: repository, isPinned: isFavorite
        )
        let run = PipelineRun(id: PipelineRunID(rawValue: runID), buildNumber: buildNumber, phase: phase)
        let date = Date(timeIntervalSince1970: 1_000)
        return MonitorObservation(
            monitor: monitor, lastKnownRun: run, attemptedAt: date,
            lastSuccessfulObservationAt: date, currentFailure: failure
        )
    }
}
