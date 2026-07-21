import Foundation

public actor MonitoringEngine: AccountLifecycleControlling {
    public enum State: Hashable, Sendable {
        case idle
        case running
        case pending
        case backingOff(until: Date)
        case pausedAuthentication
        case stopped
    }

    public typealias SnapshotHandler = @Sendable (
        _ snapshot: MonitoringSnapshot,
        _ diff: SnapshotDiff,
        _ notifications: [NotificationEvent]
    ) async -> Void

    private struct CycleContext: Sendable {
        let cycleID: UUID
        let generation: UInt64
        let configurationRevision: UInt64
        let reason: RefreshReason
        let startedAt: Date
        let configuration: AppConfiguration
        let dueMonitors: [MonitorConfiguration]
    }

    private let service: any BitbucketService
    private let configurationStore: any ConfigurationStore
    private let clock: any MonitoringClock
    private let concurrencyLimit: Int
    private let snapshotHandler: SnapshotHandler

    private var generation: UInt64 = 0
    private var configurationRevision: UInt64 = 0
    private var rootTask: Task<Void, Never>?
    private var pendingReason: RefreshReason?
    private var currentWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var automaticPolling = false
    private var isWaitingForDeadline = false
    private var consecutiveBackoffAttempts = 0
    private var rateLimitAttempts = 0
    private var globalRateLimitUntil: Date?
    private var monitorDeadlines: [MonitorID: Date] = [:]
    private var monitorRetryAttempts: [MonitorID: Int] = [:]
    private var stopped = false

    public private(set) var state: State = .idle
    public private(set) var latestSnapshot: MonitoringSnapshot?
    public private(set) var maximumObservedConcurrency = 0

    public init(
        service: any BitbucketService,
        configurationStore: any ConfigurationStore,
        clock: any MonitoringClock = SystemMonitoringClock(),
        concurrencyLimit: Int = 4,
        onSnapshot: @escaping SnapshotHandler = { _, _, _ in }
    ) {
        self.service = service
        self.configurationStore = configurationStore
        self.clock = clock
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.snapshotHandler = onSnapshot
    }

    public func start() async {
        if stopped { resume() }
        if automaticPolling {
            if rootTask == nil { await requestRefresh(reason: .retry) }
            return
        }
        automaticPolling = true
        await requestRefresh(reason: .startup)
    }

    public func refresh(reason: RefreshReason = .manual) async {
        await requestRefresh(reason: reason)
    }

    /// Requests a refresh and returns after the coalesced work has reached a stable point.
    /// Calls arriving during a cycle produce at most one follow-up cycle for that cycle.
    public func requestRefresh(reason: RefreshReason) async {
        guard !stopped else { return }
        if case let .backingOff(until) = state {
            guard await clock.now() >= until else { return }
            state = .idle
        }
        await withCheckedContinuation { continuation in
            if rootTask == nil {
                currentWaiters.append(continuation)
                launchRootTask(reason: reason)
            } else {
                pendingWaiters.append(continuation)
                pendingReason = merge(pendingReason, reason)
                if isWaitingForDeadline {
                    // Cancellation only interrupts the owned sleep. The old root exits and
                    // atomically launches one fresh root for the coalesced request.
                    rootTask?.cancel()
                } else {
                    state = .pending
                }
            }
        }
    }

    public func invalidateForAccountChange() async {
        generation &+= 1
        latestSnapshot = nil
        monitorDeadlines.removeAll()
        monitorRetryAttempts.removeAll()
        await cancelRootTask(finalState: .idle)
    }

    public func configurationDidChange() async {
        configurationRevision &+= 1
        await cancelRootTask(finalState: stopped ? .stopped : .idle)
        if automaticPolling, !stopped {
            launchRootTask(reason: .configurationChanged)
        }
    }

    public func stop() async {
        stopped = true
        automaticPolling = false
        generation &+= 1
        await cancelRootTask(finalState: .stopped)
    }

    public func resume() {
        guard stopped else { return }
        stopped = false
        state = .idle
    }

    private func launchRootTask(reason: RefreshReason) {
        let taskGeneration = generation
        let taskRevision = configurationRevision
        rootTask = Task { [weak self] in
            await self?.runRefreshLoop(
                initialReason: reason,
                taskGeneration: taskGeneration,
                taskRevision: taskRevision
            )
        }
    }

    private func runRefreshLoop(
        initialReason: RefreshReason,
        taskGeneration: UInt64,
        taskRevision: UInt64
    ) async {
        var reason = initialReason
        while !Task.isCancelled {
            guard taskGeneration == generation, taskRevision == configurationRevision else { break }
            var nextDeadline: Date?
            do {
                let configuration = try await configurationStore.load()
                consecutiveBackoffAttempts = 0
                let now = await clock.now()
                if let rateLimitUntil = globalRateLimitUntil, rateLimitUntil > now {
                    nextDeadline = rateLimitUntil
                    state = .backingOff(until: rateLimitUntil)
                    completeCurrentWaiters()
                } else {
                    globalRateLimitUntil = nil
                    let dueMonitors = monitorsDue(
                        in: configuration,
                        reason: reason,
                        now: now
                    )
                    let context = CycleContext(
                        cycleID: UUID(),
                        generation: taskGeneration,
                        configurationRevision: taskRevision,
                        reason: reason,
                        startedAt: now,
                        configuration: configuration,
                        dueMonitors: dueMonitors
                    )
                    state = .running
                    let observations = await fetchObservations(context.dueMonitors)
                    guard !Task.isCancelled else { break }
                    nextDeadline = await commit(observations: observations, context: context)
                    completeCurrentWaiters()
                }
            } catch is CancellationError {
                break
            } catch {
                // Configuration failures have no monitor to attach to. Preserve the last
                // snapshot, expose backoff state, and keep the automatic root alive.
                consecutiveBackoffAttempts += 1
                let now = await clock.now()
                let retryDeadline = now.addingTimeInterval(
                    backoffDelay(attempt: consecutiveBackoffAttempts)
                )
                nextDeadline = retryDeadline
                state = .backingOff(until: retryDeadline)
                completeCurrentWaiters()
            }

            guard !Task.isCancelled,
                  taskGeneration == generation,
                  taskRevision == configurationRevision else { break }
            if let next = pendingReason {
                promotePendingWaiters()
                reason = next
                continue
            }

            guard automaticPolling,
                  state != .pausedAuthentication,
                  let deadline = nextDeadline else { break }
            let now = await clock.now()
            let delay = deadline.timeIntervalSince(now)
            isWaitingForDeadline = true
            do {
                // A callback that outlives its deadline still yields a bounded pause,
                // preventing an immediate-cycle loop under a slow consumer.
                let boundedDelay = max(delay, 1)
                try await clock.sleep(for: .milliseconds(Int64((boundedDelay * 1_000).rounded(.up))))
            } catch {
                break
            }
            isWaitingForDeadline = false
            guard !Task.isCancelled else { break }
            if let requested = pendingReason {
                promotePendingWaiters()
                reason = requested
            } else {
                reason = .scheduled
            }
        }
        finishRootTask(taskGeneration: taskGeneration, taskRevision: taskRevision)
    }

    private func fetchObservations(
        _ monitors: [MonitorConfiguration]
    ) async -> [MonitorID: MonitorObservation] {
        var observations: [MonitorID: MonitorObservation] = [:]
        var index = monitors.startIndex

        while index < monitors.endIndex, !Task.isCancelled {
            let end = monitors.index(index, offsetBy: concurrencyLimit, limitedBy: monitors.endIndex) ?? monitors.endIndex
            let batch = Array(monitors[index..<end])
            maximumObservedConcurrency = max(maximumObservedConcurrency, batch.count)
            let service = self.service
            let attemptedAt = await clock.now()

            await withTaskGroup(of: (MonitorConfiguration, Result<PipelineRun?, ObservationFailure>).self) { group in
                for monitor in batch {
                    group.addTask {
                        do {
                            return (monitor, .success(try await service.latestPipeline(for: monitor)))
                        } catch {
                            return (monitor, .failure(Self.mapFailure(error)))
                        }
                    }
                }
                for await (monitor, result) in group {
                    let baseline = latestSnapshot?.observations[monitor.id]
                    switch result {
                    case let .success(run):
                        observations[monitor.id] = MonitorObservation(
                            monitor: monitor,
                            lastKnownRun: run,
                            attemptedAt: attemptedAt,
                            lastSuccessfulObservationAt: attemptedAt,
                            currentFailure: nil
                        )
                    case let .failure(failure):
                        observations[monitor.id] = MonitorObservation(
                            monitor: monitor,
                            lastKnownRun: baseline?.lastKnownRun,
                            attemptedAt: attemptedAt,
                            lastSuccessfulObservationAt: baseline?.lastSuccessfulObservationAt,
                            currentFailure: failure
                        )
                    }
                }
            }
            index = end
        }
        return observations
    }

    private func commit(
        observations: [MonitorID: MonitorObservation],
        context: CycleContext
    ) async -> Date? {
        guard context.generation == generation,
              context.configurationRevision == configurationRevision,
              !Task.isCancelled else { return nil }

        let completedAt = await clock.now()
        let updatedObservations = observations
        let observations = mergedObservations(
            updates: updatedObservations,
            configuration: context.configuration
        )
        let aggregate = AggregateStateReducer.reduce(
            isConnected: context.configuration.account != nil,
            observations: observations,
            now: completedAt,
            refreshIntervalSeconds: context.configuration.refreshIntervalSeconds
        )
        let hasAuthenticationFailure = observations.values.contains {
            PollingPolicy.isAuthenticationFailure($0.currentFailure)
        }
        let rateLimitDeadline = applySchedule(
            updates: updatedObservations,
            configuration: context.configuration,
            now: completedAt
        )
        let canPoll = context.configuration.account != nil && !context.configuration.monitors.isEmpty
        let nextRefreshAt: Date?
        if hasAuthenticationFailure || !canPoll {
            nextRefreshAt = nil
        } else if let rateLimitDeadline {
            globalRateLimitUntil = rateLimitDeadline
            nextRefreshAt = rateLimitDeadline
        } else {
            nextRefreshAt = monitorDeadlines.values.min()
        }
        let snapshot = MonitoringSnapshot(
            cycleID: context.cycleID,
            startedAt: context.startedAt,
            completedAt: completedAt,
            reason: context.reason,
            observations: observations,
            aggregateState: aggregate,
            nextRefreshAt: nextRefreshAt,
            isComplete: observations.count == context.configuration.monitors.count
        )
        let previous = latestSnapshot
        let diff = SnapshotDiff(previous: previous, current: snapshot)
        let notifications = NotificationPolicy.events(
            previous: previous,
            current: snapshot,
            configuration: context.configuration
        )
        latestSnapshot = snapshot
        if hasAuthenticationFailure {
            state = .pausedAuthentication
        } else if let rateLimitDeadline {
            state = .backingOff(until: rateLimitDeadline)
        } else {
            state = .idle
        }
        await snapshotHandler(snapshot, diff, notifications)
        return nextRefreshAt
    }

    private func monitorsDue(
        in configuration: AppConfiguration,
        reason: RefreshReason,
        now: Date
    ) -> [MonitorConfiguration] {
        let monitors = configuration.monitors
        let configuredIDs = Set(monitors.map(\.id))
        monitorDeadlines = monitorDeadlines.filter { configuredIDs.contains($0.key) }
        monitorRetryAttempts = monitorRetryAttempts.filter { configuredIDs.contains($0.key) }

        let mustRefreshAll: Bool
        switch reason {
        case .startup, .manual, .configurationChanged, .wake, .activation, .networkRecovery:
            mustRefreshAll = true
        default:
            mustRefreshAll = false
        }
        let hasFullCoverage = configuredIDs.allSatisfy { latestSnapshot?.observations[$0] != nil }
        let due = mustRefreshAll || !hasFullCoverage
            ? monitors
            : monitors.filter { monitorDeadlines[$0.id, default: now] <= now }
        return due.sorted { lhs, rhs in
            if lhs.workspaceSlug != rhs.workspaceSlug { return lhs.workspaceSlug < rhs.workspaceSlug }
            if lhs.repositorySlug != rhs.repositorySlug { return lhs.repositorySlug < rhs.repositorySlug }
            return lhs.id.target.displayName < rhs.id.target.displayName
        }
    }

    private func mergedObservations(
        updates: [MonitorID: MonitorObservation],
        configuration: AppConfiguration
    ) -> [MonitorID: MonitorObservation] {
        let previous = latestSnapshot?.observations ?? [:]
        return Dictionary(uniqueKeysWithValues: configuration.monitors.compactMap { monitor in
            if let update = updates[monitor.id] {
                return (monitor.id, update)
            }
            guard let baseline = previous[monitor.id] else { return nil }
            return (
                monitor.id,
                MonitorObservation(
                    monitor: monitor,
                    lastKnownRun: baseline.lastKnownRun,
                    attemptedAt: baseline.attemptedAt,
                    lastSuccessfulObservationAt: baseline.lastSuccessfulObservationAt,
                    currentFailure: baseline.currentFailure
                )
            )
        })
    }

    private func applySchedule(
        updates: [MonitorID: MonitorObservation],
        configuration: AppConfiguration,
        now: Date
    ) -> Date? {
        var rateLimitDeadline: Date?
        var sawRateLimit = false
        for (monitorID, observation) in updates {
            if PollingPolicy.isAuthenticationFailure(observation.currentFailure) {
                continue
            }
            if case .rateLimited? = observation.currentFailure {
                if !sawRateLimit {
                    rateLimitAttempts += 1
                    sawRateLimit = true
                }
                let deadline = PollingPolicy.rateLimitDeadline(
                    for: observation.currentFailure,
                    now: now,
                    attempt: rateLimitAttempts
                )
                if let deadline {
                    monitorDeadlines[monitorID] = deadline
                    rateLimitDeadline = max(rateLimitDeadline ?? deadline, deadline)
                }
                continue
            }

            if PollingPolicy.requiresIndividualBackoff(observation.currentFailure) {
                monitorRetryAttempts[monitorID, default: 0] += 1
            } else {
                monitorRetryAttempts[monitorID] = 0
            }
            monitorDeadlines[monitorID] = PollingPolicy.deadline(
                for: observation,
                now: now,
                configuredInterval: configuration.refreshIntervalSeconds,
                retryAttempt: monitorRetryAttempts[monitorID, default: 0]
            )
        }
        if !sawRateLimit { rateLimitAttempts = 0 }
        return rateLimitDeadline
    }

    private func completeCurrentWaiters() {
        let completed = currentWaiters
        currentWaiters.removeAll()
        completed.forEach { $0.resume() }
    }

    private func promotePendingWaiters() {
        currentWaiters.append(contentsOf: pendingWaiters)
        pendingWaiters.removeAll()
        pendingReason = nil
    }

    private func finishRootTask(taskGeneration: UInt64, taskRevision: UInt64) {
        rootTask = nil
        isWaitingForDeadline = false
        if !stopped,
           taskGeneration == generation,
           taskRevision == configurationRevision,
           let next = pendingReason {
            promotePendingWaiters()
            launchRootTask(reason: next)
            return
        }
        if !stopped {
            switch state {
            case .pausedAuthentication, .backingOff: break
            default: state = .idle
            }
        }
    }

    private func cancelRootTask(finalState: State) async {
        let task = rootTask
        task?.cancel()
        await task?.value
        if rootTask != nil { rootTask = nil }
        pendingReason = nil
        isWaitingForDeadline = false
        state = finalState
        let cancelledWaiters = currentWaiters + pendingWaiters
        currentWaiters.removeAll()
        pendingWaiters.removeAll()
        cancelledWaiters.forEach { $0.resume() }
    }

    private func merge(_ current: RefreshReason?, _ incoming: RefreshReason) -> RefreshReason {
        guard let current else { return incoming }
        return priority(incoming) > priority(current) ? incoming : current
    }

    private func priority(_ reason: RefreshReason) -> Int {
        switch reason {
        case .configurationChanged: 8
        case .manual: 7
        case .activation: 6
        case .networkRecovery: 5
        case .wake: 4
        case .retry: 3
        case .startup: 2
        case .scheduled: 1
        }
    }

    private func backoffDelay(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 5)
        return min(30 * pow(2, Double(exponent)), 900)
    }

    private nonisolated static func mapFailure(_ error: any Error) -> ObservationFailure {
        if let failure = error as? ObservationFailure { return failure }
        if let provider = error as? any ObservationFailureProviding {
            return provider.observationFailure
        }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .offline
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCancelled: return .cancelled
            default: break
            }
        }
        return .unexpected
    }
}
