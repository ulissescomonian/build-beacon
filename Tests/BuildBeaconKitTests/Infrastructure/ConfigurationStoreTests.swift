import Foundation
import XCTest
@testable import BuildBeaconKit

final class ConfigurationStoreTests: XCTestCase, @unchecked Sendable {
    func testMissingFileLoadsDefaultsAndRoundTripNormalizesAndDeduplicates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let store = JSONConfigurationStore(fileURL: fileURL)

        let initial = try await store.load()
        XCTAssertEqual(initial, AppConfiguration())

        let duplicate = monitor(workspaceSlug: " WORKSPACE ", repositorySlug: " Repo ")
        var configuration = AppConfiguration(monitors: [duplicate, duplicate], refreshIntervalSeconds: 120)
        configuration.notifyOnApproval = false
        try await store.save(configuration)

        let reloaded = try await JSONConfigurationStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.monitors.count, 1)
        XCTAssertEqual(reloaded.monitors[0].workspaceSlug, "workspace")
        XCTAssertEqual(reloaded.monitors[0].repositorySlug, "repo")
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 120)
        XCTAssertFalse(reloaded.notifyOnApproval)
    }

    func testActivityPreferencesRoundTripAndPruneInactiveOrDuplicateMarkers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let active = monitor()
        let inactive = MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "inactive"),
            target: .defaultBranch
        )
        let activeMarker = MonitorActivityMarker(
            monitorID: active.id,
            runID: PipelineRunID(rawValue: "run-1")
        )
        var configuration = AppConfiguration(
            monitors: [active],
            notifyOnFavoriteSuccess: true,
            unseenActivity: [
                activeMarker,
                activeMarker,
                .init(monitorID: active.id, runID: PipelineRunID(rawValue: "run-older")),
                .init(monitorID: inactive, runID: PipelineRunID(rawValue: "run-2"))
            ]
        )
        configuration.monitorPresentation.sortOrder = .recentActivity

        try await JSONConfigurationStore(fileURL: fileURL).save(configuration)
        let reloaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertTrue(reloaded.notifyOnFavoriteSuccess)
        XCTAssertEqual(reloaded.unseenActivity, [activeMarker])
        XCTAssertEqual(reloaded.monitorPresentation.sortOrder, .recentActivity)
    }

    func testV2ConfigurationMigratesToV3WithRecentActivityDefault() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        var legacy = AppConfiguration(monitors: [monitor()], refreshIntervalSeconds: 300)
        legacy.monitorPresentation.sortOrder = .status
        legacy.historyEnabled = false
        try wrappedLegacyV2Data(from: legacy).write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.refreshIntervalSeconds, 300)
        XCTAssertFalse(loaded.historyEnabled)
        XCTAssertEqual(loaded.monitorPresentation.grouping, legacy.monitorPresentation.grouping)
        XCTAssertEqual(loaded.monitorPresentation.sortOrder, .recentActivity)
        XCTAssertFalse(loaded.notifyOnFavoriteSuccess)
        XCTAssertTrue(loaded.unseenActivity.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains(where: { $0.contains("backup-v2") }))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, AppConfiguration.schemaVersion)
    }

    func testActivityPreferencesDefaultToDisabledAndEmpty() {
        let configuration = AppConfiguration()

        XCTAssertFalse(configuration.notifyOnFavoriteSuccess)
        XCTAssertTrue(configuration.unseenActivity.isEmpty)
        XCTAssertEqual(configuration.monitorPresentation.sortOrder, .recentActivity)
    }

    func testV3ConfigurationMigratesApprovalWaitDefaultsAndProductionFlag() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        try wrappedLegacyV3Data(from: AppConfiguration(monitors: [monitor()])).write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertFalse(loaded.monitors[0].isProduction)
        XCTAssertTrue(loaded.approvalWaits.isEmpty)
        XCTAssertEqual(loaded.approvalReminderInterval, .none)
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, AppConfiguration.schemaVersion)
    }

    func testV4ConfigurationMigratesAllFieldsAndDisablesPullRequestActions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        let legacy = realisticV4Configuration(monitorCount: 11)
        let original = try wrappedLegacyV4Data(from: legacy)
        try original.write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        var expected = legacy
        for index in expected.monitors.indices {
            expected.monitors[index].allowsPullRequestActions = false
        }
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.monitors.count, 11)
        XCTAssertTrue(loaded.monitors.allSatisfy { !$0.allowsPullRequestActions })

        let backupURLs = try v4BackupURLs(in: directory)
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backupURLs.first)), original)

        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, 5)
        let migratedConfiguration = try XCTUnwrap(migratedObject["configuration"] as? [String: Any])
        let migratedMonitors = try XCTUnwrap(migratedConfiguration["monitors"] as? [[String: Any]])
        XCTAssertEqual(migratedMonitors.count, 11)
        XCTAssertTrue(migratedMonitors.allSatisfy { $0["allowsPullRequestActions"] as? Bool == false })
    }

    func testV4MigrationIsIdempotentAndDoesNotCreateAnotherBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        try wrappedLegacyV4Data(from: realisticV4Configuration(monitorCount: 3))
            .write(to: fileURL, options: .atomic)
        let store = JSONConfigurationStore(fileURL: fileURL)

        let firstLoad = try await store.load()
        let migratedData = try Data(contentsOf: fileURL)
        let secondLoad = try await store.load()

        XCTAssertEqual(secondLoad, firstLoad)
        XCTAssertEqual(try Data(contentsOf: fileURL), migratedData)
        XCTAssertEqual(try v4BackupURLs(in: directory).count, 1)
        try await store.save(secondLoad)
    }

    func testV4MigrationSecuresReusedIdenticalBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        let backupURL = directory.appendingPathComponent("configuration.backup-v4-existing.json")
        let current = try wrappedLegacyV4Data(from: realisticV4Configuration(monitorCount: 2))
        try current.write(to: fileURL, options: .atomic)
        try current.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: backupURL.path
        )
        assertPermissions(backupURL, equalTo: 0o666)

        _ = try await JSONConfigurationStore(fileURL: fileURL).load()

        let backupURLs = try v4BackupURLs(in: directory)
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(backupURLs.first?.lastPathComponent, backupURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: backupURL), current)
        assertPermissions(backupURL, equalTo: 0o600)
    }

    func testV4MigrationCreatesCurrentBackupWhenExistingV4BackupHasDifferentContent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        let oldBackupURL = directory.appendingPathComponent("configuration.backup-v4-old.json")
        let oldBackup = try wrappedLegacyV4Data(from: realisticV4Configuration(monitorCount: 1))
        let current = try wrappedLegacyV4Data(from: realisticV4Configuration(monitorCount: 4))
        try oldBackup.write(to: oldBackupURL, options: .atomic)
        try current.write(to: fileURL, options: .atomic)

        _ = try await JSONConfigurationStore(fileURL: fileURL).load()

        let backupURLs = try v4BackupURLs(in: directory)
        XCTAssertEqual(backupURLs.count, 2)
        XCTAssertEqual(try Data(contentsOf: oldBackupURL), oldBackup)
        let backupContents = try backupURLs.map { try Data(contentsOf: $0) }
        XCTAssertEqual(backupContents.filter { $0 == oldBackup }.count, 1)
        XCTAssertEqual(backupContents.filter { $0 == current }.count, 1)
    }

    func testV4MigrationWriteFailurePreservesOriginalAndRequiresRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        let original = try wrappedLegacyV4Data(from: realisticV4Configuration(monitorCount: 2))
        try original.write(to: fileURL, options: .atomic)
        let store = JSONConfigurationStore(
            fileURL: fileURL,
            atomicWriter: { _, _ in throw SimulatedAtomicWriteError() }
        )

        do {
            _ = try await store.load()
            XCTFail("Expected the migration write to fail")
        } catch let error as ConfigurationStoreError {
            guard case .fileSystem = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let backupURLs = try v4BackupURLs(in: directory)
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backupURLs.first)), original)
        do {
            try await store.save(AppConfiguration())
            XCTFail("A failed migration must keep recovery required")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }
    }

    func testExternalSanitizedV4FixtureMigratesWhenProvided() async throws {
        let environmentKey = "BUILD_BEACON_V4_FIXTURE_PATH"
        guard let fixturePath = ProcessInfo.processInfo.environment[environmentKey],
              !fixturePath.isEmpty else {
            throw XCTSkip("Set \(environmentKey) to validate a sanitized schema 4 fixture")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 4)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        try original.write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertTrue(loaded.monitors.allSatisfy { !$0.allowsPullRequestActions })
        XCTAssertEqual(try v4BackupURLs(in: directory).count, 1)
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 5)
    }

    func testApprovalWaitsRoundTripAtomicallyAndPruneInactiveMarkers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let account = AccountProfile(
            id: AccountID(rawValue: "account"), displayName: "Account", email: "account@example.com"
        )
        let active = monitor()
        let inactive = MonitorID(
            accountID: account.id,
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "inactive"),
            target: .defaultBranch
        )
        try await JSONConfigurationStore(fileURL: fileURL).save(AppConfiguration(
            account: account,
            monitors: [active],
            approvalReminderInterval: .fifteenMinutes
        ))
        let later = Date(timeIntervalSinceReferenceDate: 100)
        let earliest = Date(timeIntervalSinceReferenceDate: 10)
        let valid = ApprovalWaitMarker(monitorID: active.id, runID: PipelineRunID(rawValue: "run"), firstDetectedAt: later)
        let duplicateEarlier = ApprovalWaitMarker(monitorID: active.id, runID: PipelineRunID(rawValue: "run"), firstDetectedAt: earliest)
        let inactiveMarker = ApprovalWaitMarker(monitorID: inactive, runID: PipelineRunID(rawValue: "missing"), firstDetectedAt: earliest)

        let saved = try await JSONConfigurationStore(fileURL: fileURL).saveApprovalWaits(
            [valid, duplicateEarlier, inactiveMarker], for: account.id
        )

        XCTAssertEqual(saved.approvalWaits, [duplicateEarlier])
        XCTAssertEqual(saved.approvalReminderInterval, .fifteenMinutes)
    }

    func testSaveUnseenActivityAtomicallyPreservesOtherPreferencesAndPrunesMarkers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let active = monitor()
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Account",
            email: "account@example.com"
        )
        var configuration = AppConfiguration(
            account: account,
            monitors: [active],
            refreshIntervalSeconds: 300,
            notificationsEnabled: false,
            notifyOnFailure: false,
            notifyOnFavoriteSuccess: true,
            historyEnabled: false
        )
        configuration.monitorPresentation.grouping = .project
        try await JSONConfigurationStore(fileURL: fileURL).save(configuration)

        let valid = MonitorActivityMarker(monitorID: active.id, runID: PipelineRunID(rawValue: "latest"))
        let staleRunForSameMonitor = MonitorActivityMarker(monitorID: active.id, runID: PipelineRunID(rawValue: "stale"))
        let missingMonitor = MonitorActivityMarker(
            monitorID: MonitorID(
                accountID: account.id,
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: "missing"),
                target: .defaultBranch
            ),
            runID: PipelineRunID(rawValue: "missing")
        )

        let saved = try await JSONConfigurationStore(fileURL: fileURL).saveUnseenActivity(
            [valid, staleRunForSameMonitor, missingMonitor],
            for: account.id
        )

        XCTAssertEqual(saved.unseenActivity, [valid])
        XCTAssertEqual(saved.refreshIntervalSeconds, 300)
        XCTAssertFalse(saved.notificationsEnabled)
        XCTAssertFalse(saved.notifyOnFailure)
        XCTAssertTrue(saved.notifyOnFavoriteSuccess)
        XCTAssertFalse(saved.historyEnabled)
        XCTAssertEqual(saved.monitorPresentation.grouping, .project)
    }

    func testSaveUnseenActivityRejectsAccountMismatchWithoutChangingFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Account",
            email: "account@example.com"
        )
        let active = monitor()
        let initialMarker = MonitorActivityMarker(monitorID: active.id, runID: PipelineRunID(rawValue: "initial"))
        let store = JSONConfigurationStore(fileURL: fileURL)
        try await store.save(AppConfiguration(account: account, monitors: [active], unseenActivity: [initialMarker]))
        let before = try Data(contentsOf: fileURL)

        do {
            _ = try await store.saveUnseenActivity(
                [.init(monitorID: active.id, runID: PipelineRunID(rawValue: "replacement"))],
                for: AccountID(rawValue: "different-account")
            )
            XCTFail("Expected account mismatch")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(
                error,
                .invalidConfiguration(reason: "activity markers do not match the configured account")
            )
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.unseenActivity, [initialMarker])
    }

    func testLegacyConfigurationMigratesAndPreservesBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        var monitor = monitor()
        monitor.isPinned = true
        let legacy = AppConfiguration(monitors: [monitor], refreshIntervalSeconds: 300)
        try legacyData(from: legacy).write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded, legacy)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains(where: { $0.contains("backup-v0") }))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, AppConfiguration.schemaVersion)
        XCTAssertTrue(loaded.monitors[0].isPinned)
        XCTAssertFalse(loaded.monitors[0].isHidden)
        XCTAssertEqual(loaded.monitorPresentation, .init())
        XCTAssertTrue(loaded.historyEnabled)
        let backup = try XCTUnwrap(names.first(where: { $0.contains("backup-v0") }))
        assertPermissions(directory.appendingPathComponent(backup), equalTo: 0o600)
    }

    func testWrappedV1ConfigurationMigratesToV3AndPreservesAllExistingFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        var legacy = AppConfiguration(monitors: [monitor()], refreshIntervalSeconds: 300)
        legacy.notificationsEnabled = false
        legacy.monitors[0].isPinned = true
        try wrappedLegacyV1Data(from: legacy).write(to: fileURL, options: .atomic)

        let loaded = try await JSONConfigurationStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.account, legacy.account)
        XCTAssertEqual(loaded.refreshIntervalSeconds, 300)
        XCTAssertFalse(loaded.notificationsEnabled)
        XCTAssertTrue(loaded.monitors[0].isPinned)
        XCTAssertFalse(loaded.monitors[0].isHidden)
        XCTAssertEqual(loaded.monitorPresentation, .init())
        XCTAssertTrue(loaded.historyEnabled)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains(where: { $0.contains("backup-v1") }))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, AppConfiguration.schemaVersion)
    }

    func testCorruptionIsQuarantinedAndBlocksSaveUntilReset() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = JSONConfigurationStore(fileURL: fileURL)

        let quarantineURL: URL
        do {
            _ = try await store.load()
            XCTFail("Expected a corruption error")
            return
        } catch let error as ConfigurationStoreError {
            guard case let .corrupted(url) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            quarantineURL = url
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        assertPermissions(quarantineURL, equalTo: 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        do {
            try await store.save(AppConfiguration())
            XCTFail("A recovery decision must be required")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }

        try await store.reset()
        try await store.save(AppConfiguration())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFutureSchemaIsNeverOverwritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        let futureData = Data(#"{"schemaVersion":999,"configuration":{}}"#.utf8)
        try futureData.write(to: fileURL)
        let store = JSONConfigurationStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected an unsupported schema error")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .unsupportedSchema(found: 999, supported: AppConfiguration.schemaVersion))
        }
        do {
            try await store.save(AppConfiguration())
            XCTFail("Future data must remain read-only")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), futureData)
    }

    func testInvalidRefreshIntervalIsRejectedBeforeWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let store = JSONConfigurationStore(fileURL: fileURL)

        do {
            try await store.save(AppConfiguration(refreshIntervalSeconds: 29))
            XCTFail("Expected validation failure")
        } catch let error as ConfigurationStoreError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCurrentSchemaWithMissingLegacyFieldsIsQuarantined() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        try Data(#"{"schemaVersion":2,"configuration":{}}"#.utf8).write(to: fileURL)
        let store = JSONConfigurationStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("A current schema missing legacy fields must not be accepted")
        } catch let error as ConfigurationStoreError {
            guard case .corrupted = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testHistoryEntryIdentityIncludesMonitorTarget() {
        let account = AccountID(rawValue: "account")
        let workspace = WorkspaceID(rawValue: "workspace")
        let repository = RepositoryID(rawValue: "repository")
        let latest = MonitorID(accountID: account, workspaceID: workspace, repositoryID: repository, target: .repositoryLatest)
        let branch = MonitorID(accountID: account, workspaceID: workspace, repositoryID: repository, target: .branch(exactName: "release"))
        let runID = PipelineRunID(rawValue: "same-run")

        let latestEntry = PipelineHistoryEntry(monitorID: latest, runID: runID, buildNumber: 1, phase: .running)
        let branchEntry = PipelineHistoryEntry(monitorID: branch, runID: runID, buildNumber: 1, phase: .running)

        XCTAssertNotEqual(latestEntry.id, branchEntry.id)
    }

    func testSavedConfigurationUsesPrivateDirectoryAndFilePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")

        try await JSONConfigurationStore(fileURL: fileURL).save(AppConfiguration())

        assertPermissions(directory, equalTo: 0o700)
        assertPermissions(fileURL, equalTo: 0o600)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("build-beacon-config-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertPermissions(
        _ url: URL,
        equalTo expected: NSNumber,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        #if os(macOS)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { NSNumber(value: $0 & 0o777) }, expected, file: file, line: line)
        #endif
    }

    private func legacyData(from configuration: AppConfiguration) throws -> Data {
        var object = try encodedConfigurationObject(configuration)
        object.removeValue(forKey: "monitorPresentation")
        object.removeValue(forKey: "historyEnabled")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func wrappedLegacyV1Data(from configuration: AppConfiguration) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "configuration": try encodedConfigurationObject(configuration, excludingV2Fields: true)
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func wrappedLegacyV2Data(from configuration: AppConfiguration) throws -> Data {
        var object = try encodedConfigurationObject(configuration, excludingV2Fields: false)
        object.removeValue(forKey: "notifyOnFavoriteSuccess")
        object.removeValue(forKey: "unseenActivity")
        return try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "configuration": object],
            options: [.sortedKeys]
        )
    }

    private func wrappedLegacyV3Data(from configuration: AppConfiguration) throws -> Data {
        var object = try encodedConfigurationObject(configuration, excludingV2Fields: false)
        object.removeValue(forKey: "approvalWaits")
        object.removeValue(forKey: "approvalReminderInterval")
        if var monitors = object["monitors"] as? [[String: Any]] {
            monitors = monitors.map { monitor in
                var legacy = monitor
                legacy.removeValue(forKey: "isProduction")
                return legacy
            }
            object["monitors"] = monitors
        }
        return try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 3, "configuration": object],
            options: [.sortedKeys]
        )
    }

    private func wrappedLegacyV4Data(from configuration: AppConfiguration) throws -> Data {
        var object = try encodedConfigurationObject(configuration, excludingV2Fields: false)
        if var monitors = object["monitors"] as? [[String: Any]] {
            monitors = monitors.map { monitor in
                var legacy = monitor
                legacy.removeValue(forKey: "allowsPullRequestActions")
                return legacy
            }
            object["monitors"] = monitors
        }
        return try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 4, "configuration": object],
            options: [.sortedKeys]
        )
    }

    private func encodedConfigurationObject(
        _ configuration: AppConfiguration,
        excludingV2Fields: Bool = true
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if excludingV2Fields {
            object.removeValue(forKey: "monitorPresentation")
            object.removeValue(forKey: "historyEnabled")
            if var monitors = object["monitors"] as? [[String: Any]] {
                monitors = monitors.map { monitor in
                    var legacyMonitor = monitor
                    legacyMonitor.removeValue(forKey: "isHidden")
                    return legacyMonitor
                }
                object["monitors"] = monitors
            }
        }
        return object
    }

    private func realisticV4Configuration(monitorCount: Int) -> AppConfiguration {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Operator",
            email: "operator@example.com"
        )
        let monitors = (0..<monitorCount).map { index in
            MonitorConfiguration(
                id: MonitorID(
                    accountID: account.id,
                    workspaceID: WorkspaceID(rawValue: "workspace-\(index % 2)"),
                    repositoryID: RepositoryID(rawValue: "repository-\(index)"),
                    target: index.isMultiple(of: 2)
                        ? .defaultBranch
                        : .branch(exactName: "release-\(index)")
                ),
                workspaceSlug: "workspace-\(index % 2)",
                workspaceName: "Workspace \(index % 2)",
                repositorySlug: "repository-\(index)",
                repositoryName: "Repository \(index)",
                projectName: index.isMultiple(of: 3) ? nil : "Project \(index % 3)",
                isPinned: index.isMultiple(of: 2),
                isHidden: index.isMultiple(of: 5),
                isProduction: index.isMultiple(of: 4),
                allowsPullRequestActions: true
            )
        }
        let unseenActivity = monitors.first.map {
            [MonitorActivityMarker(monitorID: $0.id, runID: PipelineRunID(rawValue: "unseen-run"))]
        } ?? []
        let approvalWaits = monitors.dropFirst().first.map {
            [ApprovalWaitMarker(
                monitorID: $0.id,
                runID: PipelineRunID(rawValue: "approval-run"),
                firstDetectedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        } ?? []
        return AppConfiguration(
            account: account,
            monitors: monitors,
            refreshIntervalSeconds: 300,
            notificationsEnabled: false,
            notifyOnFailure: false,
            notifyOnRecovery: true,
            notifyOnApproval: false,
            notifyOnFavoriteSuccess: true,
            monitorPresentation: .init(
                grouping: .project,
                sortOrder: .repository,
                favoritesFirst: false,
                hideRepositoriesWithoutRuns: true
            ),
            historyEnabled: false,
            unseenActivity: unseenActivity,
            approvalWaits: approvalWaits,
            approvalReminderInterval: .fifteenMinutes
        )
    }

    private func v4BackupURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("backup-v4") }
    }

    private func monitor(
        workspaceSlug: String = "workspace",
        repositorySlug: String = "repo"
    ) -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: AccountID(rawValue: "account"),
                workspaceID: WorkspaceID(rawValue: "workspace"),
                repositoryID: RepositoryID(rawValue: "repo"),
                target: .defaultBranch
            ),
            workspaceSlug: workspaceSlug,
            workspaceName: "Workspace",
            repositorySlug: repositorySlug,
            repositoryName: "Repository"
        )
    }
}

private struct SimulatedAtomicWriteError: Error {}
