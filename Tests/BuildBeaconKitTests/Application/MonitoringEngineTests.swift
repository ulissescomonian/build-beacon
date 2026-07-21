import XCTest
@testable import BuildBeaconKit

final class MonitoringEngineTests: XCTestCase, @unchecked Sendable {
    func testStartSchedulesSecondCycleExactlyAtDeadline() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let recorder = SnapshotRecorder()
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock) { snapshot, _, _ in
            await recorder.append(snapshot)
        }

        await engine.start()
        await clock.waitForSleepCount(1)
        var callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)

        clock.advance(by: 59)
        for _ in 0..<20 { await Task.yield() }
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)

        clock.advance(by: 1)
        await service.waitForCallCount(2)
        await clock.waitForSleepCount(2)
        let reasons = await recorder.reasons
        XCTAssertEqual(reasons, [.startup, .scheduled])
        await engine.stop()
    }

    func testAutomaticPollingDoesNotBusyLoopBeforeClockAdvances() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        for _ in 0..<200 { await Task.yield() }
        let callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(clock.recordedSleepCount, 1)
        await engine.stop()
    }

    func testOnlyRunningMonitorIsDueAtAdaptiveDeadline() async {
        let active = makeMonitor("active")
        let idle = makeMonitor("idle")
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let service = GatedPipelineService(
            automaticallyRelease: true,
            phases: [active.id: .running, idle.id: .succeeded]
        )
        let store = TestConfigurationStore(configuration: makeConfiguration([active, idle]))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        var activeCalls = await service.readCallCount(for: active.id)
        var idleCalls = await service.readCallCount(for: idle.id)
        XCTAssertEqual(activeCalls, 1)
        XCTAssertEqual(idleCalls, 1)

        clock.advance(by: 30)
        await service.waitForCallCount(3)
        activeCalls = await service.readCallCount(for: active.id)
        idleCalls = await service.readCallCount(for: idle.id)
        XCTAssertEqual(activeCalls, 2)
        XCTAssertEqual(idleCalls, 1)
        await engine.stop()
    }

    func testManualRefreshInterruptsSleepWithoutDuplicatingCycle() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        await engine.refresh(reason: .manual)
        await service.waitForCallCount(2)
        await clock.waitForSleepCount(2)
        for _ in 0..<50 { await Task.yield() }
        var callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 2)

        clock.advance(by: 60)
        await service.waitForCallCount(3)
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 3)
        await engine.stop()
    }

    func testStopCancelsScheduledSleepAndPreventsFurtherCycles() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        await engine.stop()
        let state = await engine.state
        XCTAssertEqual(clock.activeSleepCount, 0)
        XCTAssertEqual(state, .stopped)

        clock.advance(by: 600)
        for _ in 0..<50 { await Task.yield() }
        let callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testConfigurationChangeCancelsOldDeadlineAndUsesNewInterval() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        await store.setRefreshInterval(120)
        await engine.configurationDidChange()
        await service.waitForCallCount(2)
        await clock.waitForSleepCount(2)

        clock.advance(by: 119)
        for _ in 0..<20 { await Task.yield() }
        var callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 2)
        clock.advance(by: 1)
        await service.waitForCallCount(3)
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 3)
        await engine.stop()
    }

    func testAuthenticationFailurePausesWithoutScheduling() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(
            automaticallyRelease: true,
            failures: [monitor.id: .invalidCredentials]
        )
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        for _ in 0..<20 { await Task.yield() }
        let state = await engine.state
        let callCount = await service.readCallCount()
        XCTAssertEqual(state, .pausedAuthentication)
        XCTAssertEqual(clock.recordedSleepCount, 0)
        XCTAssertEqual(callCount, 1)
        await engine.stop()
    }

    func testRateLimitSleepsUntilRetryAtAndManualCannotBypassIt() async {
        let monitor = makeMonitor("one")
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let service = GatedPipelineService(
            automaticallyRelease: true,
            failures: [monitor.id: .rateLimited(retryAt: Date(timeIntervalSince1970: 1_100))]
        )
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        await engine.refresh(reason: .manual)
        var callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)
        clock.advance(by: 99)
        for _ in 0..<20 { await Task.yield() }
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)
        clock.advance(by: 1)
        await service.waitForCallCount(2)
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 2)
        await engine.stop()
    }

    func testConfigurationChangeDoesNotBypassRateLimit() async {
        let monitor = makeMonitor("one")
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let service = GatedPipelineService(
            automaticallyRelease: true,
            failures: [monitor.id: .rateLimited(retryAt: Date(timeIntervalSince1970: 1_100))]
        )
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        await engine.configurationDidChange()
        await clock.waitForSleepCount(2)
        let callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 1)

        clock.advance(by: 100)
        await service.waitForCallCount(2)
        await engine.stop()
    }

    func testInitialConfigurationLoadFailureBacksOffAndRetriesAutomatically() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        await store.failNextLoads(1)
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        var state = await engine.state
        var callCount = await service.readCallCount()
        XCTAssertEqual(state, .backingOff(until: Date(timeIntervalSince1970: 1_030)))
        XCTAssertEqual(callCount, 0)

        // Calling start again is safe and leaves the single scheduled retry intact.
        await engine.start()
        clock.advance(by: 29)
        for _ in 0..<20 { await Task.yield() }
        callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 0)
        clock.advance(by: 1)
        await service.waitForCallCount(1)
        await clock.waitForSleepCount(2)
        state = await engine.state
        XCTAssertEqual(state, .idle)
        await engine.stop()
    }

    func testServerFailuresUseIndividualExponentialBackoffAndManualCanRefresh() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(
            automaticallyRelease: true,
            failures: [monitor.id: .server(status: 503)]
        )
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
        let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)

        await engine.start()
        await clock.waitForSleepCount(1)
        clock.advance(by: 30)
        await service.waitForCallCount(2)
        await clock.waitForSleepCount(2)
        await engine.refresh(reason: .manual)
        await service.waitForCallCount(3)
        let callCount = await service.readCallCount()
        XCTAssertEqual(callCount, 3)
        await engine.stop()
    }

    func testConcreteAPIErrorsMapThroughObservationFailureProvider() async {
        let retryAt = Date(timeIntervalSince1970: 2_000)
        let cases: [(BitbucketAPIError, ObservationFailure, MonitoringEngine.State)] = [
            (.invalidCredentials, .invalidCredentials, .pausedAuthentication),
            (.insufficientPermissions, .insufficientPermissions, .pausedAuthentication),
            (.rateLimited(retryAt: retryAt), .rateLimited(retryAt: retryAt), .backingOff(until: retryAt)),
            (.notFound, .notFound, .idle),
            (.server(status: 503), .server(status: 503), .idle),
            (.transport, .unexpected, .idle),
        ]

        for (apiError, expectedFailure, expectedState) in cases {
            let monitor = makeMonitor("repo-\(String(describing: apiError))")
            let service = APIErrorPipelineService(error: apiError)
            let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
            let clock = ControllableMonitoringClock(now: Date(timeIntervalSince1970: 1_000))
            let engine = MonitoringEngine(service: service, configurationStore: store, clock: clock)
            await engine.requestRefresh(reason: .manual)
            let failure = await engine.latestSnapshot?.observations[monitor.id]?.currentFailure
            let state = await engine.state
            XCTAssertEqual(failure, expectedFailure, "Failed mapping \(apiError)")
            XCTAssertEqual(state, expectedState, "Wrong policy state for \(apiError)")
        }
    }

    func testTenRequestsDuringCycleCoalesceIntoOneFollowUp() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService()
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let recorder = SnapshotRecorder()
        let engine = MonitoringEngine(service: service, configurationStore: store) { snapshot, _, _ in
            await recorder.append(snapshot)
        }

        let initial = Task { await engine.requestRefresh(reason: .manual) }
        await service.waitForCallCount(1)
        let requests = (0..<10).map { _ in Task { await engine.requestRefresh(reason: .manual) } }
        for _ in 0..<20 { await Task.yield() }
        await service.releaseOne()
        await service.waitForCallCount(2)
        await service.releaseOne()
        await initial.value
        for request in requests { await request.value }

        let callCount = await service.callCount
        let snapshotCount = await recorder.count
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(snapshotCount, 2)
    }

    func testConcurrencyIsLimitedAndAllPartialResultsArePreserved() async {
        let monitors = (0..<7).map { makeMonitor("repo-\($0)") }
        let service = GatedPipelineService(automaticallyRelease: true, failures: [monitors[3].id: .offline])
        let store = TestConfigurationStore(configuration: makeConfiguration(monitors))
        let engine = MonitoringEngine(service: service, configurationStore: store, concurrencyLimit: 2)

        await engine.requestRefresh(reason: .startup)
        let snapshot = await engine.latestSnapshot
        let observedLimit = await engine.maximumObservedConcurrency
        let serviceLimit = await service.maximumActive
        XCTAssertEqual(snapshot?.observations.count, 7)
        XCTAssertEqual(snapshot?.observations[monitors[3].id]?.currentFailure, .offline)
        XCTAssertEqual(observedLimit, 2)
        XCTAssertLessThanOrEqual(serviceLimit, 2)
    }

    func testGenerationGuardRejectsCycleCancelledByAccountChange() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService()
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let recorder = SnapshotRecorder()
        let engine = MonitoringEngine(service: service, configurationStore: store) { snapshot, _, _ in
            await recorder.append(snapshot)
        }

        let refresh = Task { await engine.requestRefresh(reason: .manual) }
        await service.waitForCallCount(1)
        let invalidation = Task { await engine.invalidateForAccountChange() }
        await service.releaseOne()
        await invalidation.value
        await refresh.value

        let snapshot = await engine.latestSnapshot
        let snapshotCount = await recorder.count
        XCTAssertNil(snapshot)
        XCTAssertEqual(snapshotCount, 0)
    }

    func testFailedRefreshKeepsKnownRunAndMarksObservationStale() async {
        let monitor = makeMonitor("one")
        let service = GatedPipelineService(automaticallyRelease: true)
        let store = TestConfigurationStore(configuration: makeConfiguration([monitor]))
        let engine = MonitoringEngine(service: service, configurationStore: store)

        await engine.requestRefresh(reason: .startup)
        await service.setFailures([monitor.id: .offline])
        await engine.requestRefresh(reason: .manual)
        let snapshot = await engine.latestSnapshot
        let observation = snapshot?.observations[monitor.id]
        XCTAssertNotNil(observation?.lastKnownRun)
        XCTAssertEqual(observation?.currentFailure, .offline)
        XCTAssertEqual(snapshot?.aggregateState, .stale)
    }

    private func makeConfiguration(_ monitors: [MonitorConfiguration]) -> AppConfiguration {
        AppConfiguration(
            account: AccountProfile(id: AccountID(rawValue: "account"), displayName: "Account", email: "a@example.com"),
            monitors: monitors
        )
    }

    private func makeMonitor(_ repository: String) -> MonitorConfiguration {
        let id = MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: repository),
            target: .defaultBranch
        )
        return MonitorConfiguration(
            id: id, workspaceSlug: "workspace", workspaceName: "Workspace",
            repositorySlug: repository, repositoryName: repository
        )
    }
}

private actor GatedPipelineService: BitbucketService {
    private var calls = 0
    private var active = 0
    private var maxActive = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let automaticallyRelease: Bool
    private var failures: [MonitorID: ObservationFailure]
    private let phases: [MonitorID: PipelinePhase]
    private var callsByMonitor: [MonitorID: Int] = [:]

    init(
        automaticallyRelease: Bool = false,
        failures: [MonitorID: ObservationFailure] = [:],
        phases: [MonitorID: PipelinePhase] = [:]
    ) {
        self.automaticallyRelease = automaticallyRelease
        self.failures = failures
        self.phases = phases
    }

    var callCount: Int { calls }
    var maximumActive: Int { maxActive }
    func readCallCount() -> Int { calls }
    func readCallCount(for monitorID: MonitorID) -> Int { callsByMonitor[monitorID, default: 0] }

    func setFailures(_ failures: [MonitorID: ObservationFailure]) { self.failures = failures }

    func waitForCallCount(_ target: Int) async {
        if calls >= target { return }
        await withCheckedContinuation { callWaiters.append((target, $0)) }
    }

    func releaseOne() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }

    func validate(credential: AccountCredential) async throws -> AccountProfile {
        AccountProfile(id: AccountID(rawValue: "account"), displayName: "Account", email: credential.email)
    }
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] { [] }
    func listRepositories(in workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo] { [] }
    func listBranches(in repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo] { [] }

    func latestPipeline(for monitor: MonitorConfiguration) async throws -> PipelineRun? {
        calls += 1
        callsByMonitor[monitor.id, default: 0] += 1
        active += 1
        maxActive = max(maxActive, active)
        let ready = callWaiters.filter { calls >= $0.0 }
        callWaiters.removeAll { calls >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !automaticallyRelease {
            await withCheckedContinuation { gates.append($0) }
        }
        active -= 1
        if let failure = failures[monitor.id] { throw failure }
        return PipelineRun(
            id: PipelineRunID(rawValue: "run-\(monitor.repositorySlug)"),
            buildNumber: 1,
            phase: phases[monitor.id, default: .succeeded]
        )
    }
}

private actor TestConfigurationStore: ConfigurationStore {
    enum TestError: Error { case loadFailed }
    private var configuration: AppConfiguration
    private var remainingLoadFailures = 0
    init(configuration: AppConfiguration) { self.configuration = configuration }
    func setRefreshInterval(_ seconds: Int) { configuration.refreshIntervalSeconds = seconds }
    func failNextLoads(_ count: Int) { remainingLoadFailures = count }
    func load() async throws -> AppConfiguration {
        if remainingLoadFailures > 0 {
            remainingLoadFailures -= 1
            throw TestError.loadFailed
        }
        return configuration
    }
    func save(_ configuration: AppConfiguration) async throws { self.configuration = configuration }
    func reset() async throws { configuration = AppConfiguration() }
}

private struct APIErrorPipelineService: BitbucketService {
    let error: BitbucketAPIError
    func validate(credential: AccountCredential) async throws -> AccountProfile { throw error }
    func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] { throw error }
    func listRepositories(in workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo] { throw error }
    func listBranches(in repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo] { throw error }
    func latestPipeline(for monitor: MonitorConfiguration) async throws -> PipelineRun? { throw error }
}

private actor SnapshotRecorder {
    private var snapshots: [MonitoringSnapshot] = []
    var count: Int { snapshots.count }
    var reasons: [RefreshReason] { snapshots.map(\.reason) }
    func append(_ snapshot: MonitoringSnapshot) { snapshots.append(snapshot) }
}

private final class ControllableMonitoringClock: MonitoringClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepCount = 0

    init(now: Date) { currentDate = now }

    func now() async -> Date { locked { currentDate } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                var resumeImmediately = false
                locked {
                    if Task.isCancelled {
                        resumeImmediately = true
                    } else {
                        sleepCount += 1
                        sleepers[id] = Sleeper(
                            deadline: currentDate.addingTimeInterval(seconds),
                            continuation: continuation
                        )
                    }
                }
                if resumeImmediately { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.locked { self.sleepers.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    var recordedSleepCount: Int { locked { sleepCount } }
    var activeSleepCount: Int { locked { sleepers.count } }

    func waitForSleepCount(_ target: Int) async {
        while recordedSleepCount < target { await Task.yield() }
    }

    func advance(by seconds: TimeInterval) {
        let ready: [CheckedContinuation<Void, any Error>] = locked {
            currentDate = currentDate.addingTimeInterval(seconds)
            let due = sleepers.filter { $0.value.deadline <= currentDate }
            due.keys.forEach { sleepers.removeValue(forKey: $0) }
            return due.map(\.value.continuation)
        }
        ready.forEach { $0.resume() }
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
