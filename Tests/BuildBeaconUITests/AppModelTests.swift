import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testStartLoadsConfigurationAndStartsMonitoringOnce() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        let model = AppModel(runtime: runtime)

        await model.start()
        await model.start()

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.email, "owner@example.com")
        XCTAssertEqual(runtime.monitoringStarts, 1)
    }

    func testConnectNeverRetainsSubmittedToken() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        let model = AppModel(runtime: runtime)
        model.email = " owner@example.com "
        model.token = "sensitive-token"

        let connected = await model.connect()

        XCTAssertTrue(connected)
        XCTAssertEqual(model.token, "")
        XCTAssertEqual(runtime.lastConnectedEmail, "owner@example.com")
        XCTAssertEqual(runtime.lastConnectedToken, "sensitive-token")
    }

    func testStartCanRetryAfterConfigurationLoadFailure() async {
        let runtime = RuntimeStub(configuration: AppConfiguration())
        runtime.loadFailuresRemaining = 1
        let model = AppModel(runtime: runtime)

        await model.start()
        XCTAssertNotNil(model.errorMessage)

        await model.start()

        XCTAssertEqual(runtime.loadCalls, 2)
        XCTAssertEqual(runtime.monitoringStarts, 1)
    }

    func testConfigurationStoreFailuresAtStartupUseSafeLocalizedMessages() async {
        let cases: [(ConfigurationStoreError, String)] = [
            (
                .corrupted(quarantineURL: URL(fileURLWithPath: "/private/sensitive/configuration.corrupt")),
                "Build Beacon could not read the saved configuration. A recovery copy was preserved, and configuration changes are paused until it is recovered."
            ),
            (
                .unsupportedSchema(found: 99, supported: 2),
                "The saved configuration was created by a newer Build Beacon version. It was preserved unchanged. Update Build Beacon before making configuration changes."
            ),
            (
                .recoveryRequired,
                "The saved configuration requires recovery. Build Beacon preserved it and paused configuration changes. Recover the configuration before trying to save again."
            ),
            (
                .invalidConfiguration(reason: "private internal validation detail"),
                "Build Beacon could not save these configuration changes because the resulting data was invalid. The previously saved configuration was preserved."
            ),
            (
                .fileSystem(code: 513),
                "Build Beacon could not access the local configuration file. Existing data was not reset. Check this Mac's storage permissions and try again."
            ),
        ]

        for (error, key) in cases {
            let runtime = RuntimeStub(configuration: AppConfiguration())
            runtime.loadError = error
            let model = AppModel(runtime: runtime)

            await model.start()

            XCTAssertEqual(model.errorMessage, String(localized: String.LocalizationValue(key), bundle: .module))
            XCTAssertEqual(runtime.loadCalls, 1)
            XCTAssertEqual(runtime.monitoringStarts, 0)
            XCTAssertFalse(model.isConnected)
            assertNoConfigurationErrorLeak(in: model.errorMessage)
        }
    }

    func testRecoveryRequiredDuringSaveRollsBackAndUsesSafeMessage() async {
        let runtime = RuntimeStub(configuration: AppConfiguration(refreshIntervalSeconds: 60))
        let model = AppModel(runtime: runtime)
        await model.start()
        runtime.saveConfigurationError = ConfigurationStoreError.recoveryRequired

        await model.setRefreshInterval(120)

        XCTAssertEqual(model.refreshIntervalSeconds, 60)
        XCTAssertEqual(
            model.errorMessage,
            String(
                localized: "The saved configuration requires recovery. Build Beacon preserved it and paused configuration changes. Recover the configuration before trying to save again.",
                bundle: .module
            )
        )
        assertNoConfigurationErrorLeak(in: model.errorMessage)
    }

    func testInvalidConfigurationDuringSaveDoesNotExposeInternalReason() async {
        let runtime = RuntimeStub(configuration: AppConfiguration(refreshIntervalSeconds: 60))
        let model = AppModel(runtime: runtime)
        await model.start()
        runtime.saveConfigurationError = ConfigurationStoreError.invalidConfiguration(
            reason: "monitor slugs must not be empty"
        )

        await model.setRefreshInterval(120)

        XCTAssertEqual(model.refreshIntervalSeconds, 60)
        XCTAssertEqual(
            model.errorMessage,
            String(
                localized: "Build Beacon could not save these configuration changes because the resulting data was invalid. The previously saved configuration was preserved.",
                bundle: .module
            )
        )
        XCTAssertFalse(model.errorMessage?.contains("monitor slugs") == true)
        assertNoConfigurationErrorLeak(in: model.errorMessage)
    }

    func testConfigurationStoreMessagesExistInEnglishAndBrazilianPortugueseWithCatalogParity() throws {
        let keys = [
            "Build Beacon could not read the saved configuration. A recovery copy was preserved, and configuration changes are paused until it is recovered.",
            "The saved configuration was created by a newer Build Beacon version. It was preserved unchanged. Update Build Beacon before making configuration changes.",
            "The saved configuration requires recovery. Build Beacon preserved it and paused configuration changes. Recover the configuration before trying to save again.",
            "Build Beacon could not save these configuration changes because the resulting data was invalid. The previously saved configuration was preserved.",
            "Build Beacon could not access the local configuration file. Existing data was not reset. Check this Mac's storage permissions and try again.",
        ]
        let english = try localizedCatalog("en")
        let portuguese = try localizedCatalog("pt-BR")

        XCTAssertEqual(Set(english.keys), Set(portuguese.keys))
        for key in keys {
            XCTAssertFalse(try XCTUnwrap(english[key]).isEmpty)
            XCTAssertFalse(try XCTUnwrap(portuguese[key]).isEmpty)
        }
    }

    func testCancellingInitialStartWaiterDoesNotCancelWorkspaceDiscovery() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let workspace = WorkspaceInfo(id: WorkspaceID(rawValue: "workspace"), slug: "builds", name: "Builds")
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        runtime.workspaces = [workspace]
        runtime.suspendsConfigurationLoad = true
        let model = AppModel(runtime: runtime)

        let initialStart = Task { @MainActor in await model.start() }
        await runtime.waitForConfigurationLoad()
        initialStart.cancel()
        runtime.resumeConfigurationLoad()
        await initialStart.value

        await model.start()

        XCTAssertEqual(runtime.loadCalls, 1)
        XCTAssertEqual(runtime.monitoringStarts, 1)
        XCTAssertEqual(model.workspaces, [workspace])
    }

    func testConcurrentStartsCoalesceOneConfigurationLoadAndOneWorkspaceDiscovery() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        runtime.suspendsConfigurationLoad = true
        let model = AppModel(runtime: runtime)

        model.startIfNeeded()
        await runtime.waitForConfigurationLoad()
        model.startIfNeeded()
        runtime.resumeConfigurationLoad()
        await model.start()

        XCTAssertEqual(runtime.loadCalls, 1)
        XCTAssertEqual(runtime.monitoringStarts, 1)
        XCTAssertEqual(runtime.workspaceDiscoveryCalls, 1)
    }

    func testStartRetriesWorkspaceDiscoveryWithoutRestartingMonitoring() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let workspace = WorkspaceInfo(id: WorkspaceID(rawValue: "workspace"), slug: "builds", name: "Builds")
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        runtime.workspaceDiscoveryFails = true
        let model = AppModel(runtime: runtime)

        await model.start()

        XCTAssertEqual(runtime.monitoringStarts, 1)
        XCTAssertEqual(runtime.workspaceDiscoveryCalls, 1)
        XCTAssertTrue(model.workspaces.isEmpty)

        runtime.workspaceDiscoveryFails = false
        runtime.workspaces = [workspace]
        await model.start()

        XCTAssertEqual(runtime.loadCalls, 1)
        XCTAssertEqual(runtime.monitoringStarts, 1)
        XCTAssertEqual(runtime.workspaceDiscoveryCalls, 2)
        XCTAssertEqual(model.workspaces, [workspace])
    }

    func testConnectSucceedsWhenWorkspaceDiscoveryFailsAfterCredentialCommit() async {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        runtime.workspaceDiscoveryFails = true
        let model = AppModel(runtime: runtime)
        model.email = "owner@example.com"
        model.token = "sensitive-token"

        let connected = await model.connect()

        XCTAssertTrue(connected)
        XCTAssertTrue(model.isConnected)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.token, "")
    }

    func testConnectPresentsHumanReadableCredentialFailure() async {
        let runtime = RuntimeStub(configuration: AppConfiguration())
        runtime.connectError = BitbucketAPIError.invalidCredentials
        let model = AppModel(runtime: runtime)
        model.email = "owner@example.com"
        model.token = "invalid-token"

        let connected = await model.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(
            model.errorMessage,
            "Bitbucket could not authenticate this token. In Atlassian, choose Create API token with scopes, select Bitbucket, and use your Atlassian account email."
        )
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("Bitbucket") == true)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("scopes") == true)
        assertNoTechnicalErrorLeak(in: model.errorMessage)
    }

    func testConnectPresentsHumanReadablePermissionFailure() async {
        let runtime = RuntimeStub(configuration: AppConfiguration())
        runtime.connectError = BitbucketAPIError.insufficientPermissions
        let model = AppModel(runtime: runtime)
        model.email = "owner@example.com"
        model.token = "limited-token"

        let connected = await model.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(
            model.errorMessage,
            "The token is valid but is missing a required Read permission. Create a Bitbucket API token with scopes and enable all four permissions shown above."
        )
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("Bitbucket") == true)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("scopes") == true)
        assertNoTechnicalErrorLeak(in: model.errorMessage)
    }

    func testConnectPresentsHumanReadableTemporaryServiceFailure() async {
        let runtime = RuntimeStub(configuration: AppConfiguration())
        runtime.connectError = BitbucketAPIError.server(status: 503)
        let model = AppModel(runtime: runtime)
        model.email = "owner@example.com"
        model.token = "valid-token"

        let connected = await model.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(model.errorMessage, "Bitbucket is temporarily unavailable (HTTP 503). Try again shortly.")
        assertNoTechnicalErrorLeak(in: model.errorMessage)
    }

    func testAddMonitorsPersistsThreeRepositoriesInOneOperationAndRefreshesOnce() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let repositories = [
            repository("one", in: workspace, projectName: "Mobile"),
            repository("two", in: workspace, projectName: "Web"),
            repository("three", in: workspace, projectName: "Platform")
        ]

        let added = await model.addMonitors(repositories: repositories, target: .repositoryLatest)

        XCTAssertEqual(added, 3)
        XCTAssertEqual(runtime.setMonitorsCalls, 1)
        XCTAssertEqual(runtime.refreshCalls, 1)
        XCTAssertEqual(model.configuration.monitors.count, 3)
        XCTAssertEqual(model.configuration.monitors.map(\.workspaceName), [workspace.name, workspace.name, workspace.name])
        XCTAssertEqual(model.configuration.monitors.map(\.projectName), ["Mobile", "Web", "Platform"])
    }

    func testAddMonitorsIgnoresDuplicateInputAndExistingExactTarget() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let existing = repository("existing", in: workspace)
        let new = repository("new", in: workspace)
        let existingID = MonitorID(
            accountID: model.configuration.account!.id,
            workspaceID: workspace.id,
            repositoryID: existing.id,
            target: .repositoryLatest
        )
        model.configuration.monitors = [MonitorConfiguration(
            id: existingID,
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: existing.slug,
            repositoryName: existing.name
        )]

        let added = await model.addMonitors(
            repositories: [existing, new, new],
            target: .repositoryLatest
        )

        XCTAssertEqual(added, 1)
        XCTAssertEqual(runtime.setMonitorsCalls, 1)
        XCTAssertEqual(runtime.setMonitorsArguments.first?.count, 2)
        XCTAssertEqual(model.configuration.monitors.map(\.id.repositoryID), [existing.id, new.id])
    }

    func testAddMonitorsIgnoresRepositoriesFromAnotherWorkspace() async {
        let (model, runtime, _) = makeConnectedModel()
        let otherWorkspace = WorkspaceInfo(id: WorkspaceID(rawValue: "other"), slug: "other", name: "Other")

        let added = await model.addMonitors(
            repositories: [repository("outside", in: otherWorkspace)],
            target: .defaultBranch
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(runtime.setMonitorsCalls, 0)
        XCTAssertEqual(runtime.refreshCalls, 0)
        XCTAssertTrue(model.configuration.monitors.isEmpty)
    }

    func testAddMonitorsFailureDoesNotMutateConfigurationAndReturnsZero() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let before = model.configuration
        runtime.setMonitorsError = RuntimeStubError.expectedFailure

        let added = await model.addMonitors(
            repositories: [repository("one", in: workspace)],
            target: .repositoryLatest
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(runtime.setMonitorsCalls, 1)
        XCTAssertEqual(runtime.refreshCalls, 0)
        XCTAssertEqual(model.configuration, before)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFirstMonitorRequestsUndeterminedNotificationPermission() async {
        let (model, runtime, workspace) = makeConnectedModel()
        runtime.notificationStatus = NotificationPermissionStatus(
            authorization: .notDetermined,
            alertsEnabled: false,
            soundsEnabled: false
        )

        let added = await model.addMonitors(
            repositories: [repository("first", in: workspace)],
            target: .repositoryLatest
        )

        XCTAssertEqual(added, 1)
        XCTAssertEqual(runtime.notificationStatusCalls, 1)
        XCTAssertEqual(runtime.notificationPermissionRequests, 1)
        XCTAssertEqual(model.configuration.monitors.count, 1)
    }

    func testSubsequentMonitorDoesNotRequestNotificationPermissionAgain() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let existing = repository("existing", in: workspace)
        model.configuration.monitors = [MonitorConfiguration(
            id: MonitorID(
                accountID: model.configuration.account!.id,
                workspaceID: workspace.id,
                repositoryID: existing.id,
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: existing.slug,
            repositoryName: existing.name
        )]
        runtime.configuration = model.configuration

        let added = await model.addMonitors(
            repositories: [repository("next", in: workspace)],
            target: .repositoryLatest
        )

        XCTAssertEqual(added, 1)
        XCTAssertEqual(runtime.notificationStatusCalls, 0)
        XCTAssertEqual(runtime.notificationPermissionRequests, 0)
    }

    func testFirstMonitorDoesNotRequestNotificationPermissionWhenDisabled() async {
        let (model, runtime, workspace) = makeConnectedModel()
        model.notificationsEnabled = false
        runtime.configuration.notificationsEnabled = false

        let added = await model.addMonitors(
            repositories: [repository("quiet", in: workspace)],
            target: .repositoryLatest
        )

        XCTAssertEqual(added, 1)
        XCTAssertEqual(runtime.notificationStatusCalls, 0)
        XCTAssertEqual(runtime.notificationPermissionRequests, 0)
    }

    func testRefreshAfterActivationOnlyRunsWhenSnapshotIsDue() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = MonitorConfiguration(
            id: MonitorID(
                accountID: model.configuration.account!.id,
                workspaceID: workspace.id,
                repositoryID: RepositoryID(rawValue: "repository"),
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: "repository",
            repositoryName: "Repository"
        )
        model.configuration.monitors = [monitor]
        let now = Date(timeIntervalSince1970: 10_000)
        runtime.refreshSnapshot = snapshot(
            monitor: monitor,
            nextRefreshAt: now.addingTimeInterval(30)
        )
        await model.refresh(reason: .startup)

        await model.refreshIfDueAfterActivation(now: now)
        XCTAssertEqual(runtime.refreshReasons, [.startup])

        await model.refreshIfDueAfterActivation(now: now.addingTimeInterval(31))
        XCTAssertEqual(runtime.refreshReasons, [.startup, .activation])
    }

    func testToggleFavoritePersistsEntireConfigurationAtomically() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let repository = repository("favorite", in: workspace)
        let monitor = MonitorConfiguration(
            id: MonitorID(
                accountID: model.configuration.account!.id,
                workspaceID: workspace.id,
                repositoryID: repository.id,
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: repository.slug,
            repositoryName: repository.name
        )
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration

        await model.toggleFavorite(for: monitor.id)

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
    }

    func testToggleFavoriteUpdatesVisibleSnapshotBeforeConfigurationSaveCompletes() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let first = monitor(id: "first", in: workspace, accountID: model.configuration.account!.id)
        let favorite = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, favorite]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .scheduled,
            observations: [
                first.id: MonitorObservation(monitor: first),
                favorite.id: MonitorObservation(monitor: favorite)
            ],
            aggregateState: .healthy
        )
        await model.refresh()
        model.selectedMonitorID = favorite.id
        runtime.suspendsConfigurationSave = true

        let toggle = Task { @MainActor in
            await model.toggleFavorite(for: favorite.id)
        }
        await runtime.waitForConfigurationSave()

        XCTAssertTrue(model.configuration.monitors[1].isPinned)
        XCTAssertTrue(model.snapshot?.observations[favorite.id]?.monitor.isPinned == true)
        XCTAssertTrue(model.selectedObservation?.monitor.isPinned == true)
        XCTAssertEqual(model.selectedMonitorID, favorite.id)
        XCTAssertFalse(runtime.configuration.monitors[1].isPinned)
        let visible = DashboardOrganization.visibleObservations(
            model.sortedObservations,
            projectFilter: .all,
            searchText: "",
            preferences: model.monitorPresentation
        )
        XCTAssertEqual(visible.map(\.monitor.id), [favorite.id, first.id])

        runtime.resumeConfigurationSave()
        await toggle.value

        XCTAssertTrue(runtime.configuration.monitors[1].isPinned)
    }

    func testBeginFavoriteToggleUpdatesConfigurationAndSnapshotBeforeReturning() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let first = monitor(id: "first", in: workspace, accountID: model.configuration.account!.id)
        let favorite = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, favorite]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .scheduled,
            observations: [
                first.id: MonitorObservation(monitor: first),
                favorite.id: MonitorObservation(monitor: favorite)
            ],
            aggregateState: .healthy
        )
        await model.refresh()
        runtime.suspendsConfigurationSave = true

        let persistence = model.beginFavoriteToggle(for: favorite.id)

        XCTAssertNotNil(persistence)
        XCTAssertTrue(model.configuration.monitors[1].isPinned)
        XCTAssertTrue(model.snapshot?.observations[favorite.id]?.monitor.isPinned == true)
        XCTAssertEqual(model.sortedObservations.map(\.monitor.id), [favorite.id, first.id])
        XCTAssertFalse(runtime.configuration.monitors[1].isPinned)

        await runtime.waitForConfigurationSave()
        XCTAssertFalse(runtime.configuration.monitors[1].isPinned)
        runtime.resumeConfigurationSave()
        await persistence?.value

        XCTAssertTrue(runtime.configuration.monitors[1].isPinned)
    }

    func testToggleFavoriteRestoresVisibleSnapshotWhenConfigurationSaveFails() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let favorite = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [favorite]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: favorite, nextRefreshAt: nil)
        await model.refresh()
        model.selectedMonitorID = favorite.id
        runtime.suspendsConfigurationSave = true
        runtime.saveConfigurationError = RuntimeStubError.expectedFailure

        let toggle = Task { @MainActor in
            await model.toggleFavorite(for: favorite.id)
        }
        await runtime.waitForConfigurationSave()

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(model.selectedObservation?.monitor.isPinned == true)

        runtime.resumeConfigurationSave()
        await toggle.value

        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(model.selectedObservation?.monitor.isPinned == false)
        XCTAssertEqual(model.selectedMonitorID, favorite.id)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRapidFavoriteOnThenOffAcceptsBothClicksAndPersistsTheirOrder() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitored = monitor(id: "rapid", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitored]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let pin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await runtime.waitForConfigurationSave()
        let unpin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await Task.yield()

        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        runtime.resumeConfigurationSave()
        await pin.value
        await unpin.value

        XCTAssertEqual(runtime.saveConfigurationCalls, 2)
        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        XCTAssertFalse(runtime.configuration.monitors[0].isPinned)
    }

    func testRapidFavoriteOffThenOnAcceptsBothClicksAndPersistsTheirOrder() async {
        let (model, runtime, workspace) = makeConnectedModel()
        var monitored = monitor(id: "rapid", in: workspace, accountID: model.configuration.account!.id)
        monitored.isPinned = true
        model.configuration.monitors = [monitored]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let unpin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await runtime.waitForConfigurationSave()
        let pin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await Task.yield()

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        runtime.resumeConfigurationSave()
        await unpin.value
        await pin.value

        XCTAssertEqual(runtime.saveConfigurationCalls, 2)
        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
    }

    func testRapidFavoriteTogglesForDifferentMonitorsBothPersist() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let first = monitor(id: "first", in: workspace, accountID: model.configuration.account!.id)
        let second = monitor(id: "second", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, second]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let firstToggle = Task { @MainActor in await model.toggleFavorite(for: first.id) }
        await runtime.waitForConfigurationSave()
        let secondToggle = Task { @MainActor in await model.toggleFavorite(for: second.id) }
        await Task.yield()

        XCTAssertTrue(model.configuration.monitors.allSatisfy(\.isPinned))
        runtime.resumeConfigurationSave()
        await firstToggle.value
        await secondToggle.value

        XCTAssertEqual(runtime.saveConfigurationCalls, 2)
        XCTAssertTrue(runtime.configuration.monitors.allSatisfy(\.isPinned))
    }

    func testFailedOlderFavoriteSaveCannotOverrideNewerFavoriteIntent() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitored = monitor(id: "failure", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitored]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let pin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await runtime.waitForConfigurationSave()
        let unpin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        runtime.saveConfigurationFailuresRemaining = 1
        runtime.resumeConfigurationSave()
        await pin.value
        await unpin.value

        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        XCTAssertFalse(runtime.configuration.monitors[0].isPinned)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedFavoriteForOneMonitorDoesNotReintroduceItWhenLaterMonitorPersists() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let first = monitor(id: "first-failure", in: workspace, accountID: model.configuration.account!.id)
        let second = monitor(id: "second-success", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, second]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let firstToggle = Task { @MainActor in await model.toggleFavorite(for: first.id) }
        await runtime.waitForConfigurationSave()
        let secondToggle = Task { @MainActor in await model.toggleFavorite(for: second.id) }
        runtime.saveConfigurationFailuresRemaining = 1
        runtime.resumeConfigurationSave()
        await firstToggle.value
        await secondToggle.value

        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(model.configuration.monitors[1].isPinned)
        XCTAssertFalse(runtime.configuration.monitors[0].isPinned)
        XCTAssertTrue(runtime.configuration.monitors[1].isPinned)
    }

    func testFailedLatestFavoriteIntentRollsBackToLastConfirmedState() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitored = monitor(id: "latest-failure", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitored]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let pin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        await runtime.waitForConfigurationSave()
        let unpin = Task { @MainActor in await model.toggleFavorite(for: monitored.id) }
        runtime.saveConfigurationFailureCallNumbers = [2]
        runtime.resumeConfigurationSave()
        await pin.value
        await unpin.value

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
        XCTAssertNotNil(model.errorMessage)
    }

    func testStructuralMonitorMutationsWaitForPendingFavoritePersistence() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let favorite = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        let removable = monitor(id: "removable", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [favorite, removable]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let toggle = Task { @MainActor in await model.toggleFavorite(for: favorite.id) }
        await runtime.waitForConfigurationSave()
        await model.removeMonitor(removable.id)
        XCTAssertEqual(runtime.setMonitorsCalls, 0)

        runtime.resumeConfigurationSave()
        await toggle.value
        await model.removeMonitor(removable.id)

        XCTAssertEqual(runtime.setMonitorsCalls, 1)
        XCTAssertEqual(model.configuration.monitors.map(\.id), [favorite.id])
    }

    func testFavoriteSaveDoesNotDiscardNewUnseenActivityCreatedWhileItIsSuspended() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "first", buildNumber: 1)
        await model.refresh()
        runtime.suspendsConfigurationSave = true

        let favorite = Task { @MainActor in
            await model.toggleFavorite(for: monitor.id)
        }
        await runtime.waitForConfigurationSave()

        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "second", buildNumber: 2)
        await model.refresh()
        XCTAssertEqual(model.configuration.unseenActivity.map(\.runID), [PipelineRunID(rawValue: "second")])

        runtime.resumeConfigurationSave()
        await favorite.value
        await settleActivityPersistence()

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertEqual(model.configuration.unseenActivity.map(\.runID), [PipelineRunID(rawValue: "second")])
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
        XCTAssertEqual(runtime.configuration.unseenActivity.map(\.runID), [PipelineRunID(rawValue: "second")])
    }

    func testOverlappingFavoriteAndPreferenceSavesPreserveBothLatestIntentions() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let favorite = Task { @MainActor in
            await model.toggleFavorite(for: monitor.id)
        }
        await runtime.waitForConfigurationSave()

        let preferences = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await Task.yield()
        runtime.resumeConfigurationSave()
        await favorite.value
        await preferences.value

        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertFalse(model.configuration.notificationsEnabled)
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
        XCTAssertFalse(runtime.configuration.notificationsEnabled)
    }

    func testFailedFavoriteRollsBackBeforeQueuedPreferenceIsPersisted() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let favorite = Task { @MainActor in
            await model.toggleFavorite(for: monitor.id)
        }
        await runtime.waitForConfigurationSave()
        let preference = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await Task.yield()

        runtime.saveConfigurationFailuresRemaining = 1
        runtime.resumeConfigurationSave()
        await favorite.value
        await preference.value

        XCTAssertFalse(model.configuration.monitors[0].isPinned)
        XCTAssertFalse(model.configuration.notificationsEnabled)
        XCTAssertFalse(runtime.configuration.monitors[0].isPinned)
        XCTAssertFalse(runtime.configuration.notificationsEnabled)
    }

    func testFailedPreferenceRollsBackBeforeQueuedFavoriteIsPersisted() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "favorite", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.suspendsConfigurationSave = true

        let preference = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await runtime.waitForConfigurationSave()
        let favorite = Task { @MainActor in
            await model.toggleFavorite(for: monitor.id)
        }
        await Task.yield()

        runtime.saveConfigurationFailuresRemaining = 1
        runtime.resumeConfigurationSave()
        await preference.value
        await favorite.value

        XCTAssertTrue(model.configuration.notificationsEnabled)
        XCTAssertTrue(model.configuration.monitors[0].isPinned)
        XCTAssertTrue(runtime.configuration.notificationsEnabled)
        XCTAssertTrue(runtime.configuration.monitors[0].isPinned)
    }

    func testStaleSuspendedPreferenceFailureCannotRollBackOrReportIntoNewAccountSession() async {
        let (model, runtime, _) = makeConnectedModel()
        runtime.suspendsConfigurationSave = true

        let preference = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await runtime.waitForConfigurationSave()

        let disconnect = Task { @MainActor in
            await model.disconnect()
        }
        await Task.yield()
        runtime.saveConfigurationFailuresRemaining = 1
        runtime.resumeConfigurationSave()
        await preference.value
        await disconnect.value

        XCTAssertNil(model.configuration.account)
        XCTAssertTrue(model.configuration.notificationsEnabled)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(runtime.configuration.account)
        XCTAssertEqual(runtime.saveConfigurationCalls, 1)
    }

    func testDisconnectWaitsForSuspendedConfigurationSaveThenWinsDurably() async {
        let (model, runtime, _) = makeConnectedModel()
        runtime.suspendsConfigurationSave = true

        let preference = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await runtime.waitForConfigurationSave()
        let disconnect = Task { @MainActor in
            await model.disconnect()
        }
        await Task.yield()

        XCTAssertNotNil(runtime.configuration.account)
        runtime.resumeConfigurationSave()
        await preference.value
        await disconnect.value

        XCTAssertNil(model.configuration.account)
        XCTAssertNil(runtime.configuration.account)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedPreferenceSettlesBeforeFailedAccountBarrier() async {
        let (model, runtime, _) = makeConnectedModel()
        runtime.suspendsConfigurationSave = true

        let preference = Task { @MainActor in
            await model.setNotificationsEnabled(false)
        }
        await runtime.waitForConfigurationSave()
        let disconnect = Task { @MainActor in
            await model.disconnect()
        }
        await Task.yield()

        runtime.saveConfigurationFailuresRemaining = 1
        runtime.disconnectError = ObservationFailure.offline
        runtime.resumeConfigurationSave()
        await preference.value
        await disconnect.value

        XCTAssertTrue(model.configuration.notificationsEnabled)
        XCTAssertTrue(runtime.configuration.notificationsEnabled)
        XCTAssertNotNil(model.configuration.account)
        XCTAssertNotNil(runtime.configuration.account)
        XCTAssertEqual(model.errorMessage, "The Mac appears to be offline.")
    }

    func testSavePresentationAndHistoryPreferencePersistsTogether() async {
        let (model, runtime, _) = makeConnectedModel()
        let preferences = MonitorPresentationPreferences(
            grouping: .project,
            sortOrder: .repository,
            favoritesFirst: false,
            hideRepositoriesWithoutRuns: true
        )

        await model.saveMonitorPresentation(preferences)
        await model.setHistoryEnabled(false)

        XCTAssertEqual(model.monitorPresentation, preferences)
        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(runtime.configuration.monitorPresentation, preferences)
        XCTAssertFalse(runtime.configuration.historyEnabled)
    }

    func testInitialSnapshotDoesNotMarkExistingRunAsUnseen() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "baseline", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "first", buildNumber: 1)

        await model.refresh()
        await settleActivityPersistence()

        XCTAssertEqual(model.unseenActivityCount, 0)
        XCTAssertFalse(model.isActivityUnseen(model.selectedObservation!))
        XCTAssertEqual(runtime.saveUnseenActivityCalls, 0)
    }

    func testApprovalDetectionPersistsFirstTimestampAndClearsAfterSuccessfulAdvance() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "approval", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        let detectedAt = Date(timeIntervalSinceReferenceDate: 100)
        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(), startedAt: detectedAt, completedAt: detectedAt, reason: .scheduled,
            observations: [monitor.id: MonitorObservation(
                monitor: monitor,
                lastKnownRun: PipelineRun(id: PipelineRunID(rawValue: "wait"), buildNumber: 4, phase: .awaitingApproval)
            )],
            aggregateState: .awaitingApproval
        )

        await model.refresh()
        await settleActivityPersistence()

        XCTAssertEqual(model.approvalDetectedAt(for: monitor.id, runID: PipelineRunID(rawValue: "wait")), detectedAt)
        XCTAssertEqual(runtime.configuration.approvalWaits, model.configuration.approvalWaits)
        XCTAssertEqual(runtime.saveApprovalWaitsCalls, 1)

        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(), startedAt: detectedAt, completedAt: detectedAt.addingTimeInterval(60), reason: .scheduled,
            observations: [monitor.id: MonitorObservation(
                monitor: monitor,
                lastKnownRun: PipelineRun(id: PipelineRunID(rawValue: "wait"), buildNumber: 4, phase: .running)
            )],
            aggregateState: .running
        )
        await model.refresh()
        await settleActivityPersistence()

        XCTAssertNil(model.approvalDetectedAt(for: monitor.id, runID: PipelineRunID(rawValue: "wait")))
        XCTAssertTrue(runtime.configuration.approvalWaits.isEmpty)
    }

    func testApprovalReminderAndProductionPreferencesPersist() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "production", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration

        model.setApprovalReminderInterval(.tenMinutes)
        await settleActivityPersistence()
        await model.setMonitorProduction(true, for: monitor.id)

        XCTAssertEqual(model.approvalReminderInterval, .tenMinutes)
        XCTAssertEqual(runtime.configuration.approvalReminderInterval, .tenMinutes)
        XCTAssertTrue(runtime.configuration.monitors[0].isProduction)
        XCTAssertEqual(runtime.reconciledApprovalReminders.last?.1, .tenMinutes)
    }

    func testPullRequestActionConfigurationClearsTokenBufferAfterUse() async {
        let (_, runtime, _) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: false)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        model.pullRequestActionEmail = "actions@example.com"
        model.pullRequestActionToken = "secret-token"

        let configured = await model.configurePullRequestActions()
        let configuredEmail = await actions.configuredEmail()

        XCTAssertTrue(configured)
        XCTAssertTrue(model.pullRequestActionIsConfigured)
        XCTAssertTrue(model.pullRequestActionToken.isEmpty)
        XCTAssertEqual(configuredEmail, "actions@example.com")
    }

    func testPullRequestActionPreflightIsSingleFlightAndMergeRefreshesTerminalState() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        let observation = pullRequestObservation(monitor: monitor, runID: "run-1", buildNumber: 10, commitHash: "abc")
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()

        let first = model.beginPullRequestAction(for: observation)
        let duplicate = model.beginPullRequestAction(for: observation)
        await first?.value

        XCTAssertNil(duplicate)
        guard case let .confirmation(preflight) = model.pullRequestActionSheetState else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertEqual(preflight.target.runID, PipelineRunID(rawValue: "run-1"))
        await model.confirmPullRequestAction(strategy: .mergeCommit)?.value
        let approveCalls = await actions.approveCallCount()

        XCTAssertEqual(approveCalls, 1)
        XCTAssertEqual(runtime.refreshCalls, 2)
        XCTAssertEqual(model.pullRequestActionSheetState, .completed(outcome: .merged(mergeCommitHash: "merged")))
    }

    func testPullRequestActionConfirmationRejectsLocallyStaleRunBeforeMutation() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        let original = pullRequestObservation(monitor: monitor, runID: "run-1", buildNumber: 10, commitHash: "abc")
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: original)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        await model.beginPullRequestAction(for: original)?.value

        let newer = pullRequestObservation(monitor: monitor, runID: "run-2", buildNumber: 11, commitHash: "def")
        runtime.refreshSnapshot = snapshot(observation: newer)
        await model.refresh()
        let confirmation = model.confirmPullRequestAction(strategy: .mergeCommit)
        let approveCalls = await actions.approveCallCount()

        XCTAssertNil(confirmation)
        XCTAssertEqual(approveCalls, 0)
        XCTAssertEqual(model.pullRequestActionSheetState, .failed(error: .staleRun))
    }

    func testPullRequestActionCancellationBeforeConfirmationIsSafe() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        let observation = pullRequestObservation(monitor: monitor, runID: "run-safe-cancel", buildNumber: 12, commitHash: "abc")
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        await model.beginPullRequestAction(for: observation)?.value

        model.cancelPullRequestAction()
        let approveCalls = await actions.approveCallCount()

        XCTAssertEqual(model.pullRequestActionSheetState, .hidden)
        XCTAssertEqual(approveCalls, 0)
    }

    func testPullRequestActionCancellationAfterConfirmationIsOutcomeUnknown() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        let observation = pullRequestObservation(monitor: monitor, runID: "run-unknown-cancel", buildNumber: 13, commitHash: "abc")
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        await model.beginPullRequestAction(for: observation)?.value

        let action = model.confirmPullRequestAction(strategy: .mergeCommit)
        model.cancelPullRequestAction()
        await action?.value

        XCTAssertEqual(model.pullRequestActionSheetState, .failed(error: .outcomeUnknown))
    }

    func testPullRequestActionsTogglePersistsPerMonitor() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "actions-toggle", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration

        await model.setPullRequestActionsAllowed(true, for: monitor.id)

        XCTAssertTrue(model.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertTrue(runtime.configuration.monitors[0].allowsPullRequestActions)
    }

    func testEnablePullRequestActionsAndBeginReviewPersistsThenStartsPreflight() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let observation = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "enable-review",
            buildNumber: 14,
            commitHash: "abc"
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()

        let preflight = await model.enablePullRequestActionsAndBeginReview(for: observation)
        await preflight?.value
        let preflightCalls = await actions.preflightCallCount()

        XCTAssertTrue(model.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertTrue(runtime.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertEqual(preflightCalls, 1)
        guard case .confirmation = model.pullRequestActionSheetState else {
            return XCTFail("Expected confirmation after persisted opt-in")
        }
    }

    func testEnablePullRequestActionsAndBeginReviewRejectsMissingActionsTokenWithoutPersistence() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: false)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let observation = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "missing-token",
            buildNumber: 15,
            commitHash: "abc"
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()

        let preflight = await model.enablePullRequestActionsAndBeginReview(for: observation)
        let preflightCalls = await actions.preflightCallCount()

        XCTAssertNil(preflight)
        XCTAssertFalse(model.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertEqual(runtime.saveConfigurationCalls, 0)
        XCTAssertEqual(preflightCalls, 0)
        XCTAssertEqual(model.pullRequestActionSheetState, .failed(error: .notConfigured))
    }

    func testEnablePullRequestActionsAndBeginReviewRejectsInvalidCandidateWithoutPersistence() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let observation = MonitorObservation(
            monitor: disabledMonitor,
            lastKnownRun: PipelineRun(
                id: PipelineRunID(rawValue: "invalid-candidate"),
                buildNumber: 16,
                phase: .succeeded,
                origin: .pullRequest(
                    id: 42,
                    sourceBranch: "feature/actions",
                    destinationBranch: "main"
                ),
                commitHash: "abc"
            )
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()

        let preflight = await model.enablePullRequestActionsAndBeginReview(for: observation)
        let preflightCalls = await actions.preflightCallCount()

        XCTAssertNil(preflight)
        XCTAssertFalse(model.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertEqual(runtime.saveConfigurationCalls, 0)
        XCTAssertEqual(preflightCalls, 0)
        XCTAssertEqual(model.pullRequestActionSheetState, .failed(error: .invalidTarget))
    }

    func testEnablePullRequestActionsAndBeginReviewRestoresDisabledMonitorWhenPersistenceFails() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let observation = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "persistence-failure",
            buildNumber: 17,
            commitHash: "abc"
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        runtime.saveConfigurationError = RuntimeStubError.expectedFailure

        let preflight = await model.enablePullRequestActionsAndBeginReview(for: observation)
        let preflightCalls = await actions.preflightCallCount()

        XCTAssertNil(preflight)
        XCTAssertFalse(model.configuration.monitors[0].allowsPullRequestActions)
        XCTAssertFalse(model.selectedObservation?.monitor.allowsPullRequestActions == true)
        XCTAssertEqual(preflightCalls, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testEnablePullRequestActionsAndBeginReviewDoesNotPreflightWhenTargetChangesDuringPersistence() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let original = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "original-target",
            buildNumber: 18,
            commitHash: "abc"
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: original)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        runtime.suspendsConfigurationSave = true

        let enabling = Task { @MainActor in
            await model.enablePullRequestActionsAndBeginReview(for: original)
        }
        await runtime.waitForConfigurationSave()
        let changed = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "changed-target",
            buildNumber: 19,
            commitHash: "def"
        )
        runtime.refreshSnapshot = snapshot(observation: changed)
        await model.refresh()
        runtime.resumeConfigurationSave()
        let preflight = await enabling.value
        let preflightCalls = await actions.preflightCallCount()

        XCTAssertNil(preflight)
        XCTAssertEqual(preflightCalls, 0)
        XCTAssertEqual(model.pullRequestActionSheetState, .failed(error: .staleRun))
    }

    func testEnablePullRequestActionsAndBeginReviewReservesSingleFlightBeforeDurableOptIn() async {
        let (_, runtime, workspace) = makeConnectedModel()
        let actions = PullRequestActionServiceStub(configured: true)
        let model = AppModel(runtime: runtime, pullRequestActions: actions)
        await model.start()
        let monitor = pullRequestMonitor(in: workspace, accountID: model.configuration.account!.id)
        var disabledMonitor = monitor
        disabledMonitor.allowsPullRequestActions = false
        let observation = pullRequestObservation(
            monitor: disabledMonitor,
            runID: "single-flight-opt-in",
            buildNumber: 20,
            commitHash: "abc"
        )
        model.configuration.monitors = [disabledMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(observation: observation)
        await model.refresh()
        await model.refreshPullRequestActionConfigurationStatus()
        runtime.suspendsConfigurationSave = true

        let first = Task { @MainActor in
            await model.enablePullRequestActionsAndBeginReview(for: observation)
        }
        await runtime.waitForConfigurationSave()
        let second = await model.enablePullRequestActionsAndBeginReview(for: observation)
        let beforeResumeCalls = await actions.preflightCallCount()

        XCTAssertNil(second)
        XCTAssertEqual(beforeResumeCalls, 0)
        runtime.resumeConfigurationSave()
        let firstPreflight = await first.value
        await firstPreflight?.value
        let afterResumeCalls = await actions.preflightCallCount()

        XCTAssertEqual(afterResumeCalls, 1)
        guard case .confirmation = model.pullRequestActionSheetState else {
            return XCTFail("Expected exactly one confirmation after durable opt-in")
        }
    }

    func testDisablingGlobalNotificationsCancelsApprovalRemindersImmediately() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "reminder-global", in: workspace, accountID: model.configuration.account!.id)
        let marker = ApprovalWaitMarker(
            monitorID: monitor.id,
            runID: PipelineRunID(rawValue: "waiting"),
            firstDetectedAt: .now
        )
        model.configuration.monitors = [monitor]
        model.configuration.approvalWaits = [marker]
        runtime.configuration = model.configuration
        model.setApprovalReminderInterval(.tenMinutes)
        await settleActivityPersistence()

        await model.setNotificationsEnabled(false)

        XCTAssertEqual(runtime.reconciledApprovalReminders.last?.0, [])
        XCTAssertEqual(runtime.reconciledApprovalReminders.last?.1, ApprovalReminderInterval.none)
    }

    func testDisablingApprovalNotificationsCancelsApprovalRemindersImmediately() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "reminder-approval", in: workspace, accountID: model.configuration.account!.id)
        let marker = ApprovalWaitMarker(
            monitorID: monitor.id,
            runID: PipelineRunID(rawValue: "waiting"),
            firstDetectedAt: .now
        )
        model.configuration.monitors = [monitor]
        model.configuration.approvalWaits = [marker]
        runtime.configuration = model.configuration

        model.notifyOnApproval = false
        await model.saveNotificationPreferences()

        XCTAssertEqual(runtime.reconciledApprovalReminders.last?.0, [])
        XCTAssertEqual(runtime.reconciledApprovalReminders.last?.1, ApprovalReminderInterval.none)
    }

    func testLaterNewRunMarksMonitorUnseenAndPersistsIt() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "new-run", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "first", buildNumber: 1)
        await model.refresh()
        await settleActivityPersistence()

        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "second", buildNumber: 2)
        await model.refresh()
        await settleActivityPersistence()

        XCTAssertEqual(model.unseenActivityCount, 1)
        XCTAssertEqual(model.configuration.unseenActivity, [
            MonitorActivityMarker(monitorID: monitor.id, runID: PipelineRunID(rawValue: "second"))
        ])
        XCTAssertTrue(model.isActivityUnseen(model.selectedObservation!))
        XCTAssertEqual(runtime.configuration.unseenActivity, model.configuration.unseenActivity)
        XCTAssertEqual(runtime.saveUnseenActivityCalls, 1)
    }

    func testConsecutiveSnapshotsBeforePersistenceSettlesKeepBothNewMarkers() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let first = monitor(id: "first-consecutive", in: workspace, accountID: model.configuration.account!.id)
        let second = monitor(id: "second-consecutive", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, second]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(), startedAt: .now, completedAt: .now, reason: .scheduled,
            observations: [
                first.id: observation(monitor: first, runID: "first-1", buildNumber: 1),
                second.id: observation(monitor: second, runID: "second-1", buildNumber: 1)
            ], aggregateState: .healthy
        )
        await model.refresh()

        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(), startedAt: .now, completedAt: .now, reason: .scheduled,
            observations: [
                first.id: observation(monitor: first, runID: "first-2", buildNumber: 2),
                second.id: observation(monitor: second, runID: "second-1", buildNumber: 1)
            ], aggregateState: .healthy
        )
        await model.refresh()
        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(), startedAt: .now, completedAt: .now, reason: .scheduled,
            observations: [
                first.id: observation(monitor: first, runID: "first-2", buildNumber: 2),
                second.id: observation(monitor: second, runID: "second-2", buildNumber: 2)
            ], aggregateState: .healthy
        )
        await model.refresh()
        await settleActivityPersistence()

        let expected: Set<MonitorActivityMarker> = [
            MonitorActivityMarker(monitorID: first.id, runID: PipelineRunID(rawValue: "first-2")),
            MonitorActivityMarker(monitorID: second.id, runID: PipelineRunID(rawValue: "second-2"))
        ]
        XCTAssertEqual(Set(model.configuration.unseenActivity), expected)
        XCTAssertEqual(Set(runtime.configuration.unseenActivity), expected)
    }

    func testFirstObservationForNewMonitorInLaterSnapshotIsSilentBaseline() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let original = monitor(id: "original", in: workspace, accountID: model.configuration.account!.id)
        let addedLater = monitor(id: "added-later", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [original, addedLater]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: original, runID: "original-run", buildNumber: 1)
        await model.refresh()
        await settleActivityPersistence()

        runtime.refreshSnapshot = MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .scheduled,
            observations: [
                original.id: observation(monitor: original, runID: "original-run", buildNumber: 1),
                addedLater.id: observation(monitor: addedLater, runID: "new-monitor-run", buildNumber: 1)
            ],
            aggregateState: .healthy
        )
        await model.refresh()
        await settleActivityPersistence()

        XCTAssertEqual(model.unseenActivityCount, 0)
        XCTAssertTrue(model.configuration.unseenActivity.isEmpty)
        XCTAssertFalse(model.isActivityUnseen(model.snapshot!.observations[addedLater.id]!))
    }

    func testChangingAccountsResetsSnapshotBaselineBeforeReconnectRefresh() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let firstMonitor = monitor(id: "first-account", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [firstMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: firstMonitor, runID: "first-run", buildNumber: 1)
        await model.refresh()

        let secondAccount = AccountProfile(
            id: AccountID(rawValue: "second-account"),
            displayName: "Second Owner",
            email: "second@example.com"
        )
        let secondWorkspace = WorkspaceInfo(id: WorkspaceID(rawValue: "second-workspace"), slug: "second", name: "Second")
        let secondMonitor = monitor(id: "second-monitor", in: secondWorkspace, accountID: secondAccount.id)
        runtime.configuration = AppConfiguration(account: secondAccount, monitors: [secondMonitor])
        runtime.refreshSnapshot = snapshot(monitor: secondMonitor, runID: "second-run", buildNumber: 1)
        model.email = secondAccount.email
        model.token = "token"

        let connected = await model.connect()
        XCTAssertTrue(connected)
        await settleActivityPersistence()

        XCTAssertEqual(model.configuration.account?.id, secondAccount.id)
        XCTAssertEqual(model.unseenActivityCount, 0)
        XCTAssertTrue(model.configuration.unseenActivity.isEmpty)
    }

    func testStalePersistedMarkerIsNotCountedWhenCurrentRunDiffers() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "stale-marker", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        model.configuration.unseenActivity = [
            MonitorActivityMarker(monitorID: monitor.id, runID: PipelineRunID(rawValue: "old-run"))
        ]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "current-run", buildNumber: 2)

        await model.refresh()
        await settleActivityPersistence()

        XCTAssertEqual(model.unseenActivityCount, 0)
        XCTAssertFalse(model.isActivityUnseen(model.selectedObservation!))
        XCTAssertTrue(model.configuration.unseenActivity.isEmpty)
        XCTAssertTrue(runtime.configuration.unseenActivity.isEmpty)
        XCTAssertEqual(runtime.saveUnseenActivityCalls, 1)
    }

    func testPendingActivityWriteForPreviousAccountCannotOverwriteNewAccount() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let firstMonitor = monitor(id: "pending-first", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [firstMonitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: firstMonitor, runID: "first-1", buildNumber: 1)
        await model.refresh()
        runtime.suspendsUnseenActivitySave = true
        runtime.refreshSnapshot = snapshot(monitor: firstMonitor, runID: "first-2", buildNumber: 2)
        await model.refresh()
        await runtime.waitForUnseenActivitySave()

        let secondAccount = AccountProfile(
            id: AccountID(rawValue: "replacement-account"),
            displayName: "Replacement",
            email: "replacement@example.com"
        )
        let secondWorkspace = WorkspaceInfo(id: WorkspaceID(rawValue: "replacement-workspace"), slug: "replacement", name: "Replacement")
        let secondMonitor = monitor(id: "replacement-monitor", in: secondWorkspace, accountID: secondAccount.id)
        runtime.configuration = AppConfiguration(account: secondAccount, monitors: [secondMonitor])
        runtime.refreshSnapshot = snapshot(monitor: secondMonitor, runID: "replacement-1", buildNumber: 1)
        model.email = secondAccount.email
        model.token = "token"
        let connect = Task { @MainActor in
            await model.connect()
        }
        await Task.yield()
        runtime.resumeUnseenActivitySave()
        let connected = await connect.value
        XCTAssertTrue(connected)
        await settleActivityPersistence()

        XCTAssertEqual(model.configuration.account?.id, secondAccount.id)
        XCTAssertTrue(model.configuration.unseenActivity.isEmpty)
        XCTAssertEqual(runtime.configuration.account?.id, secondAccount.id)
        XCTAssertTrue(runtime.configuration.unseenActivity.isEmpty)
    }

    func testSelectingOrAcknowledgingActivityRemovesPersistedMarker() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "acknowledge", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        model.configuration.unseenActivity = [
            MonitorActivityMarker(monitorID: monitor.id, runID: PipelineRunID(rawValue: "run"))
        ]
        runtime.configuration = model.configuration

        await model.selectMonitor(monitor.id)

        XCTAssertEqual(model.selectedMonitorID, monitor.id)
        XCTAssertEqual(model.unseenActivityCount, 0)
        XCTAssertTrue(runtime.configuration.unseenActivity.isEmpty)
        XCTAssertEqual(runtime.saveUnseenActivityCalls, 1)
    }

    func testActivityPersistenceFailureRestoresPreviousConfiguration() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "rollback", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "first", buildNumber: 1)
        await model.refresh()
        await settleActivityPersistence()

        runtime.saveUnseenActivityError = RuntimeStubError.expectedFailure
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "second", buildNumber: 2)
        await model.refresh()
        await settleActivityPersistence()

        XCTAssertTrue(model.configuration.unseenActivity.isEmpty)
        XCTAssertTrue(runtime.configuration.unseenActivity.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSaveNotificationPreferencesPersistsFavoriteSuccessToggle() async {
        let (model, runtime, _) = makeConnectedModel()
        model.notifyOnFavoriteSuccess = true

        await model.saveNotificationPreferences()

        XCTAssertTrue(model.configuration.notifyOnFavoriteSuccess)
        XCTAssertTrue(runtime.configuration.notifyOnFavoriteSuccess)
    }

    func testLoadAndClearSelectedHistory() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = MonitorConfiguration(
            id: MonitorID(
                accountID: model.configuration.account!.id,
                workspaceID: workspace.id,
                repositoryID: RepositoryID(rawValue: "history"),
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: "history",
            repositoryName: "History"
        )
        model.selectedMonitorID = monitor.id
        runtime.history[monitor.id] = [PipelineHistoryEntry(
            monitorID: monitor.id,
            runID: PipelineRunID(rawValue: "run"),
            buildNumber: 7,
            phase: .succeeded
        )]

        let loaded = await model.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(model.selectedHistory, loaded)

        await model.clearHistory()
        XCTAssertTrue(model.selectedHistory.isEmpty)
        XCTAssertNil(runtime.history[monitor.id])
    }

    func testNotificationPermissionMethodsUpdateModelAndTestRoute() async {
        let (model, runtime, _) = makeConnectedModel()
        let expected = NotificationPermissionStatus(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: true
        )
        runtime.notificationStatus = expected

        let current = await model.refreshNotificationPermissionStatus()
        let requested = await model.requestNotificationPermission()
        let route = NotificationRoute(monitorID: MonitorID(
            accountID: model.configuration.account!.id,
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "repository"),
            target: .repositoryLatest
        ))
        await model.sendTestNotification(route: route)

        XCTAssertEqual(current, expected)
        XCTAssertEqual(requested, expected)
        XCTAssertEqual(model.notificationPermissionStatus, expected)
        XCTAssertEqual(runtime.testNotificationRoutes, [route])
    }

    func testNotificationRouteSelectsItsOriginalMonitorAndBuild() async {
        let (model, _, workspace) = makeConnectedModel()
        let monitorID = MonitorID(
            accountID: model.configuration.account!.id,
            workspaceID: workspace.id,
            repositoryID: RepositoryID(rawValue: "notified"),
            target: .repositoryLatest
        )
        model.configuration.monitors = [MonitorConfiguration(
            id: monitorID,
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: "notified",
            repositoryName: "Notified"
        )]
        let route = NotificationRoute(
            monitorID: monitorID,
            runID: PipelineRunID(rawValue: "original-run"),
            buildNumber: 42
        )

        model.handleNotificationRoute(route)

        XCTAssertEqual(model.selectedMonitorID, monitorID)
        XCTAssertEqual(model.selectedPipelineRunID, PipelineRunID(rawValue: "original-run"))
        XCTAssertEqual(model.selectedBuildNumber, 42)
    }

    func testReminderRouteWithoutBuildNumberOpensCurrentMatchingRun() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "reminder-route", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "waiting", buildNumber: 51)
        await model.refresh()

        model.openPipelineBuildURL(for: NotificationRoute(
            monitorID: monitor.id,
            runID: PipelineRunID(rawValue: "waiting")
        ))

        XCTAssertEqual(runtime.openedPipelineBuilds.count, 1)
        XCTAssertEqual(runtime.openedPipelineBuilds.first?.0, monitor.id)
        XCTAssertEqual(runtime.openedPipelineBuilds.first?.1, 51)
    }

    func testReminderRouteWithoutBuildNumberNeverOpensDifferentCurrentRun() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "reminder-route-mismatch", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [monitor]
        runtime.configuration = model.configuration
        runtime.refreshSnapshot = snapshot(monitor: monitor, runID: "newer", buildNumber: 52)
        await model.refresh()

        model.openPipelineBuildURL(for: NotificationRoute(
            monitorID: monitor.id,
            runID: PipelineRunID(rawValue: "older")
        ))

        XCTAssertTrue(runtime.openedPipelineBuilds.isEmpty)
    }

    func testSelectedNotificationBuildBelongsOnlyToItsSelectedMonitor() async {
        let (model, _, workspace) = makeConnectedModel()
        let first = monitor(id: "first", in: workspace, accountID: model.configuration.account!.id)
        let second = monitor(id: "second", in: workspace, accountID: model.configuration.account!.id)
        model.configuration.monitors = [first, second]
        model.handleNotificationRoute(NotificationRoute(monitorID: first.id, buildNumber: 11))

        XCTAssertEqual(model.selectedNotificationBuildNumber, 11)
        model.selectedMonitorID = second.id
        XCTAssertNil(model.selectedNotificationBuildNumber)
    }

    func testPipelineAndBitbucketLinksIgnoreMissingURLs() async {
        let (model, runtime, workspace) = makeConnectedModel()
        let monitor = monitor(id: "links", in: workspace, accountID: model.configuration.account!.id)
        let runWithoutCommitURL = PipelineRun(
            id: PipelineRunID(rawValue: "run"),
            buildNumber: 1,
            phase: .succeeded,
            commitContext: PipelineCommitContext()
        )
        let pullRequestWithoutURL = PipelinePullRequestContext(id: 4, title: "PR", state: "OPEN")

        model.openCommitURL(runWithoutCommitURL)
        model.openPullRequestURL(pullRequestWithoutURL)
        model.openPipelineBuildURL(monitor: monitor, buildNumber: 9)

        XCTAssertTrue(runtime.openedBitbucketURLs.isEmpty)
        XCTAssertEqual(runtime.openedPipelineBuilds.count, 1)
        XCTAssertEqual(runtime.openedPipelineBuilds.first?.0, monitor.id)
        XCTAssertEqual(runtime.openedPipelineBuilds.first?.1, 9)
    }

    private func makeConnectedModel() -> (AppModel, RuntimeStub, WorkspaceInfo) {
        let account = AccountProfile(
            id: AccountID(rawValue: "account"),
            displayName: "Build Owner",
            email: "owner@example.com"
        )
        let workspace = WorkspaceInfo(id: WorkspaceID(rawValue: "workspace"), slug: "builds", name: "Builds")
        let runtime = RuntimeStub(configuration: AppConfiguration(account: account))
        let model = AppModel(runtime: runtime)
        model.configuration = runtime.configuration
        model.selectedWorkspace = workspace
        return (model, runtime, workspace)
    }

    private func repository(
        _ name: String,
        in workspace: WorkspaceInfo,
        projectName: String? = nil
    ) -> RepositoryInfo {
        RepositoryInfo(
            id: RepositoryID(rawValue: name),
            workspaceID: workspace.id,
            workspaceSlug: workspace.slug,
            slug: name,
            name: name.capitalized,
            projectName: projectName
        )
    }

    private func monitor(id: String, in workspace: WorkspaceInfo, accountID: AccountID) -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: accountID,
                workspaceID: workspace.id,
                repositoryID: RepositoryID(rawValue: id),
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: id,
            repositoryName: id.capitalized
        )
    }

    private func snapshot(
        monitor: MonitorConfiguration,
        nextRefreshAt: Date?
    ) -> MonitoringSnapshot {
        MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .startup,
            observations: [monitor.id: MonitorObservation(monitor: monitor)],
            aggregateState: .healthy,
            nextRefreshAt: nextRefreshAt
        )
    }

    private func snapshot(
        monitor: MonitorConfiguration,
        runID: String,
        buildNumber: Int
    ) -> MonitoringSnapshot {
        MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .scheduled,
            observations: [monitor.id: observation(monitor: monitor, runID: runID, buildNumber: buildNumber)],
            aggregateState: .healthy
        )
    }

    private func observation(
        monitor: MonitorConfiguration,
        runID: String,
        buildNumber: Int
    ) -> MonitorObservation {
        MonitorObservation(
            monitor: monitor,
            lastKnownRun: PipelineRun(
                id: PipelineRunID(rawValue: runID),
                buildNumber: buildNumber,
                phase: .succeeded
            )
        )
    }

    private func pullRequestMonitor(
        in workspace: WorkspaceInfo,
        accountID: AccountID
    ) -> MonitorConfiguration {
        MonitorConfiguration(
            id: MonitorID(
                accountID: accountID,
                workspaceID: workspace.id,
                repositoryID: RepositoryID(rawValue: "pull-request-actions"),
                target: .repositoryLatest
            ),
            workspaceSlug: workspace.slug,
            workspaceName: workspace.name,
            repositorySlug: "pull-request-actions",
            repositoryName: "Pull Request Actions",
            isProduction: true,
            allowsPullRequestActions: true
        )
    }

    private func pullRequestObservation(
        monitor: MonitorConfiguration,
        runID: String,
        buildNumber: Int,
        commitHash: String
    ) -> MonitorObservation {
        MonitorObservation(
            monitor: monitor,
            lastKnownRun: PipelineRun(
                id: PipelineRunID(rawValue: runID),
                buildNumber: buildNumber,
                phase: .succeeded,
                origin: .pullRequest(
                    id: 42,
                    sourceBranch: "feature/actions",
                    destinationBranch: "main"
                ),
                commitHash: commitHash,
                pullRequest: PipelinePullRequestContext(
                    id: 42,
                    title: "Merge actions",
                    state: "OPEN",
                    sourceCommitHash: commitHash,
                    availableMergeStrategies: [.mergeCommit],
                    defaultMergeStrategy: .mergeCommit
                )
            )
        )
    }

    private func snapshot(observation: MonitorObservation) -> MonitoringSnapshot {
        MonitoringSnapshot(
            cycleID: UUID(),
            startedAt: .now,
            completedAt: .now,
            reason: .manual,
            observations: [observation.monitor.id: observation],
            aggregateState: .healthy
        )
    }

    private func settleActivityPersistence() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private func assertNoTechnicalErrorLeak(in message: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(message, file: file, line: line)
        XCTAssertFalse(message?.contains("BuildBeaconKit") == true, file: file, line: line)
        XCTAssertFalse(message?.localizedCaseInsensitiveContains("error 6") == true, file: file, line: line)
        XCTAssertFalse(message?.localizedCaseInsensitiveContains("error n") == true, file: file, line: line)
    }

    private func assertNoConfigurationErrorLeak(
        in message: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertNoTechnicalErrorLeak(in: message, file: file, line: line)
        XCTAssertFalse(message?.contains("ConfigurationStoreError") == true, file: file, line: line)
        XCTAssertFalse(message?.contains("/private/") == true, file: file, line: line)
        XCTAssertFalse(message?.contains("513") == true, file: file, line: line)
        XCTAssertFalse(message?.contains("99") == true, file: file, line: line)
        XCTAssertFalse(message?.contains("private internal") == true, file: file, line: line)
    }

    private func localizedCatalog(_ localization: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            )
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }
}

private enum RuntimeStubError: Error {
    case expectedFailure
}

@MainActor
private final class RuntimeStub: BuildBeaconRuntime {
    var configuration: AppConfiguration
    var monitoringStarts = 0
    var loadCalls = 0
    var loadFailuresRemaining = 0
    var loadError: (any Error)?
    var workspaceDiscoveryFails = false
    var workspaceDiscoveryCalls = 0
    var workspaces: [WorkspaceInfo] = []
    var suspendsConfigurationLoad = false
    var connectError: (any Error)?
    var disconnectError: (any Error)?
    var lastConnectedEmail: String?
    var lastConnectedToken: String?
    var setMonitorsCalls = 0
    var setMonitorsArguments: [[MonitorConfiguration]] = []
    var setMonitorsError: (any Error)?
    var saveConfigurationError: (any Error)?
    var saveConfigurationFailuresRemaining = 0
    var saveConfigurationFailureCallNumbers: Set<Int> = []
    var saveConfigurationCalls = 0
    var suspendsConfigurationSave = false
    var saveUnseenActivityError: (any Error)?
    var saveUnseenActivityCalls = 0
    var saveApprovalWaitsError: (any Error)?
    var saveApprovalWaitsCalls = 0
    var reconciledApprovalReminders: [([ApprovalWaitMarker], ApprovalReminderInterval)] = []
    var suspendsUnseenActivitySave = false
    var refreshCalls = 0
    var refreshReasons: [RefreshReason] = []
    var refreshSnapshot: MonitoringSnapshot?
    var history: [MonitorID: [PipelineHistoryEntry]] = [:]
    var notificationStatus = NotificationPermissionStatus(
        authorization: .notDetermined,
        alertsEnabled: false,
        soundsEnabled: false
    )
    var notificationStatusCalls = 0
    var notificationPermissionRequests = 0
    var testNotificationRoutes: [NotificationRoute] = []
    var openedPipelineBuilds: [(MonitorID, Int)] = []
    var openedBitbucketURLs: [URL] = []
    private var configurationLoadContinuation: CheckedContinuation<Void, Never>?
    private var configurationLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var unseenActivitySaveContinuation: CheckedContinuation<Void, Never>?
    private var unseenActivitySaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var configurationSaveContinuation: CheckedContinuation<Void, Never>?
    private var configurationSaveWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func loadConfiguration() async throws -> AppConfiguration {
        loadCalls += 1
        configurationLoadWaiters.forEach { $0.resume() }
        configurationLoadWaiters = []
        if suspendsConfigurationLoad {
            await withCheckedContinuation { continuation in
                configurationLoadContinuation = continuation
            }
        }
        if loadFailuresRemaining > 0 {
            loadFailuresRemaining -= 1
            throw loadError ?? RuntimeStubError.expectedFailure
        }
        if let loadError { throw loadError }
        return configuration
    }

    func waitForConfigurationLoad() async {
        guard loadCalls > 0 else {
            await withCheckedContinuation { continuation in
                configurationLoadWaiters.append(continuation)
            }
            return
        }
    }

    func resumeConfigurationLoad() {
        suspendsConfigurationLoad = false
        configurationLoadContinuation?.resume()
        configurationLoadContinuation = nil
    }

    func waitForConfigurationSave() async {
        guard saveConfigurationCalls > 0 else {
            await withCheckedContinuation { continuation in
                configurationSaveWaiters.append(continuation)
            }
            return
        }
    }

    func resumeConfigurationSave() {
        suspendsConfigurationSave = false
        configurationSaveContinuation?.resume()
        configurationSaveContinuation = nil
    }

    func waitForUnseenActivitySave() async {
        guard saveUnseenActivityCalls > 0 else {
            await withCheckedContinuation { continuation in
                unseenActivitySaveWaiters.append(continuation)
            }
            return
        }
    }

    func resumeUnseenActivitySave() {
        suspendsUnseenActivitySave = false
        unseenActivitySaveContinuation?.resume()
        unseenActivitySaveContinuation = nil
    }

    func connect(email: String, token: String) async throws -> AppConfiguration {
        lastConnectedEmail = email
        lastConnectedToken = token
        if let connectError { throw connectError }
        return configuration
    }

    func revalidate() async throws -> AppConfiguration { configuration }

    func disconnect() async throws -> AppConfiguration {
        if let disconnectError { throw disconnectError }
        configuration.account = nil
        return configuration
    }

    func startMonitoring(_ sink: @escaping @Sendable (MonitoringSnapshot) -> Void) async {
        monitoringStarts += 1
    }

    func refresh(reason: RefreshReason) async -> MonitoringSnapshot? {
        refreshCalls += 1
        refreshReasons.append(reason)
        return refreshSnapshot
    }

    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] {
        workspaceDiscoveryCalls += 1
        if workspaceDiscoveryFails { throw RuntimeStubError.expectedFailure }
        return workspaces
    }

    func listRepositories(
        workspace: WorkspaceInfo,
        accountID: AccountID
    ) async throws -> [RepositoryInfo] { [] }

    func listBranches(
        repository: RepositoryInfo,
        accountID: AccountID
    ) async throws -> [BranchInfo] { [] }

    func setMonitors(_ monitors: [MonitorConfiguration]) async throws -> AppConfiguration {
        setMonitorsCalls += 1
        setMonitorsArguments.append(monitors)
        if let setMonitorsError { throw setMonitorsError }
        configuration.monitors = monitors
        return configuration
    }

    func saveConfiguration(_ configuration: AppConfiguration) async throws -> AppConfiguration {
        saveConfigurationCalls += 1
        configurationSaveWaiters.forEach { $0.resume() }
        configurationSaveWaiters = []
        if suspendsConfigurationSave {
            await withCheckedContinuation { continuation in
                configurationSaveContinuation = continuation
            }
        }
        if saveConfigurationFailuresRemaining > 0 {
            saveConfigurationFailuresRemaining -= 1
            throw saveConfigurationError ?? RuntimeStubError.expectedFailure
        }
        if saveConfigurationFailureCallNumbers.remove(saveConfigurationCalls) != nil {
            throw saveConfigurationError ?? RuntimeStubError.expectedFailure
        }
        if let saveConfigurationError { throw saveConfigurationError }
        self.configuration = configuration
        return configuration
    }

    func saveUnseenActivity(
        _ markers: [MonitorActivityMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        saveUnseenActivityCalls += 1
        unseenActivitySaveWaiters.forEach { $0.resume() }
        unseenActivitySaveWaiters = []
        if suspendsUnseenActivitySave {
            await withCheckedContinuation { continuation in
                unseenActivitySaveContinuation = continuation
            }
        }
        if let saveUnseenActivityError { throw saveUnseenActivityError }
        guard configuration.account?.id == accountID else { throw RuntimeStubError.expectedFailure }
        configuration.unseenActivity = markers
        return configuration
    }

    func saveApprovalWaits(
        _ markers: [ApprovalWaitMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        saveApprovalWaitsCalls += 1
        if let saveApprovalWaitsError { throw saveApprovalWaitsError }
        guard configuration.account?.id == accountID else { throw RuntimeStubError.expectedFailure }
        configuration.approvalWaits = markers
        return configuration
    }

    func reconcileApprovalReminders(
        activeApprovals: [ApprovalWaitMarker],
        interval: ApprovalReminderInterval
    ) async {
        reconciledApprovalReminders.append((activeApprovals, interval))
    }

    func history(for monitorID: MonitorID) async throws -> [PipelineHistoryEntry] {
        history[monitorID] ?? []
    }

    func clearHistory(for monitorID: MonitorID) async throws {
        history[monitorID] = nil
    }

    func notificationPermissionStatus() async throws -> NotificationPermissionStatus {
        notificationStatusCalls += 1
        return notificationStatus
    }

    func requestNotificationPermission() async throws -> NotificationPermissionStatus {
        notificationPermissionRequests += 1
        return notificationStatus
    }

    func sendTestNotification(route: NotificationRoute) async throws {
        testNotificationRoutes.append(route)
    }

    func openNotificationSettings() throws { }

    func openPipeline(_ observation: MonitorObservation) throws { }
    func openPipeline(monitor: MonitorConfiguration, buildNumber: Int) throws {
        openedPipelineBuilds.append((monitor.id, buildNumber))
    }
    func openBitbucketURL(_ url: URL) throws { openedBitbucketURLs.append(url) }
    func launchAtLoginEnabled() -> Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) async throws { }
}

private actor PullRequestActionServiceStub: PullRequestActionServicing {
    private var configured: Bool
    private var email: String?
    private var approveCalls = 0
    private var preflightCalls = 0
    var outcome: PullRequestMergeOutcome = .merged(mergeCommitHash: "merged")
    var preflightError: PullRequestActionError?
    var actionError: PullRequestActionError?

    init(configured: Bool) {
        self.configured = configured
    }

    var isConfigured: Bool { configured }

    func configure(_ credential: AccountCredential, expectedAccountID: AccountID) async throws {
        guard !credential.email.isEmpty, !credential.token.isEmpty else {
            throw PullRequestActionError.invalidCredentials
        }
        email = credential.email
        configured = true
    }

    func disconnectPullRequestActions() async throws {
        configured = false
    }

    func preflight(_ target: PullRequestActionTarget) async throws -> PullRequestMergePreflight {
        preflightCalls += 1
        guard configured else { throw PullRequestActionError.notConfigured }
        if let preflightError { throw preflightError }
        return PullRequestMergePreflight(
            target: target,
            title: "Merge actions",
            availableStrategies: [.mergeCommit],
            defaultStrategy: .mergeCommit,
            closeSourceBranch: false,
            alreadyApproved: false
        )
    }

    func approveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy
    ) async throws -> PullRequestMergeOutcome {
        approveCalls += 1
        if let actionError { throw actionError }
        return outcome
    }

    func configuredEmail() -> String? { email }
    func approveCallCount() -> Int { approveCalls }
    func preflightCallCount() -> Int { preflightCalls }
}
