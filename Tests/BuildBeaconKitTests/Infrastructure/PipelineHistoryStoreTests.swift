import Foundation
import XCTest
@testable import BuildBeaconKit

final class PipelineHistoryStoreTests: XCTestCase, @unchecked Sendable {
    func testRecordsSanitizedEntryAndUpsertsSameRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONPipelineHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let base = Date(timeIntervalSince1970: 1_000)

        try await store.record(observation: observation(run: run(phase: .running)), at: base)
        try await store.record(
            observation: observation(run: run(phase: .succeeded, completedAt: base.addingTimeInterval(10))),
            at: base.addingTimeInterval(10)
        )

        let entries = try await store.entries(for: monitor().id, at: base.addingTimeInterval(10))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].phase, .succeeded)
        XCTAssertEqual(entries[0].completedAt, base.addingTimeInterval(10))

        let raw = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("feature/private-branch"))
        XCTAssertFalse(raw.contains("deadbeef"))
        XCTAssertFalse(raw.contains("private failure reason"))
        XCTAssertFalse(raw.contains("private step"))
    }

    func testDoesNotRecordFailuresOrEmptyRuns() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONPipelineHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let failed = MonitorObservation(monitor: monitor(), lastKnownRun: run(), currentFailure: .offline)
        let empty = MonitorObservation(monitor: monitor())

        try await store.record(observation: failed, at: .now)
        try await store.record(observation: empty, at: .now)

        let entries = try await store.entries(for: monitor().id, at: .now)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    func testPrunesByRetentionPerMonitorAndGlobalCap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONPipelineHistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            maximumRunsPerMonitor: 2,
            retentionInterval: 100,
            maximumEntryCount: 3
        )
        let base = Date(timeIntervalSince1970: 1_000)
        let firstMonitor = monitor(repository: "one")
        let secondMonitor = monitor(repository: "two")

        try await store.record(observation: observation(monitor: firstMonitor, run: run(id: "expired")), at: base)
        try await store.record(observation: observation(monitor: firstMonitor, run: run(id: "one")), at: base.addingTimeInterval(101))
        try await store.record(observation: observation(monitor: firstMonitor, run: run(id: "two")), at: base.addingTimeInterval(102))
        try await store.record(observation: observation(monitor: firstMonitor, run: run(id: "three")), at: base.addingTimeInterval(103))
        try await store.record(observation: observation(monitor: secondMonitor, run: run(id: "four")), at: base.addingTimeInterval(104))

        let first = try await store.entries(for: firstMonitor.id, at: base.addingTimeInterval(104))
        let second = try await store.entries(for: secondMonitor.id, at: base.addingTimeInterval(104))
        XCTAssertEqual(first.map(\.runID.rawValue), ["three", "two"])
        XCTAssertEqual(second.map(\.runID.rawValue), ["four"])
    }

    func testRemoveAndRemoveAllForAccount() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONPipelineHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let one = monitor(repository: "one")
        let two = monitor(repository: "two")
        let other = monitor(account: "other", repository: "three")

        try await store.record(observation: observation(monitor: one, run: run(id: "one")), at: .now)
        try await store.record(observation: observation(monitor: two, run: run(id: "two")), at: .now)
        try await store.record(observation: observation(monitor: other, run: run(id: "three")), at: .now)
        try await store.remove(for: one.id)
        let removed = try await store.entries(for: one.id, at: .now)
        let retained = try await store.entries(for: two.id, at: .now)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.count, 1)

        try await store.removeAll(for: AccountID(rawValue: "account"))
        let removedAccount = try await store.entries(for: two.id, at: .now)
        let retainedOtherAccount = try await store.entries(for: other.id, at: .now)
        XCTAssertTrue(removedAccount.isEmpty)
        XCTAssertEqual(retainedOtherAccount.count, 1)
    }

    func testCorruptionIsQuarantinedAndFutureSchemaIsProtected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corruptURL)
        let corruptStore = JSONPipelineHistoryStore(fileURL: corruptURL)

        do {
            _ = try await corruptStore.entries(for: monitor().id, at: .now)
            XCTFail("Expected corruption")
        } catch let error as PipelineHistoryStoreError {
            guard case let .corrupted(quarantineURL) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        }
        do {
            try await corruptStore.record(observation: observation(run: run()), at: .now)
            XCTFail("Expected recovery requirement")
        } catch let error as PipelineHistoryStoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }

        let futureURL = directory.appendingPathComponent("future.json")
        let future = Data(#"{"schemaVersion":999,"entries":[]}"#.utf8)
        try future.write(to: futureURL)
        let futureStore = JSONPipelineHistoryStore(fileURL: futureURL)
        do {
            _ = try await futureStore.entries(for: monitor().id, at: .now)
            XCTFail("Expected unsupported schema")
        } catch let error as PipelineHistoryStoreError {
            XCTAssertEqual(error, .unsupportedSchema(found: 999, supported: 1))
        }
        XCTAssertEqual(try Data(contentsOf: futureURL), future)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("build-beacon-history-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func monitor(account: String = "account", repository: String = "repo") -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: AccountID(rawValue: account),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: repository),
                target: .defaultBranch
            ),
            workspaceSlug: "workspace",
            workspaceName: "Workspace",
            repositorySlug: repository,
            repositoryName: repository
        )
    }

    private func observation(monitor: MonitorConfiguration, run: PipelineRun) -> MonitorObservation {
        MonitorObservation(monitor: monitor, lastKnownRun: run)
    }

    private func observation(run: PipelineRun) -> MonitorObservation {
        observation(monitor: monitor(), run: run)
    }

    private func run(
        id: String = "run",
        phase: PipelinePhase = .running,
        completedAt: Date? = nil
    ) -> PipelineRun {
        PipelineRun(
            id: PipelineRunID(rawValue: id),
            buildNumber: 42,
            phase: phase,
            branchName: "feature/private-branch",
            commitHash: "deadbeefcafebabe",
            startedAt: Date(timeIntervalSince1970: 900),
            completedAt: completedAt,
            failureReason: "private failure reason",
            steps: [PipelineStep(id: PipelineStepID(rawValue: "step"), name: "private step", phase: .running)]
        )
    }
}
