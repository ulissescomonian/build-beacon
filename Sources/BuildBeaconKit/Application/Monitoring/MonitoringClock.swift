import Foundation

public protocol MonitoringClock: Sendable {
    func now() async -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemMonitoringClock: MonitoringClock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public protocol AccountLifecycleControlling: Sendable {
    func invalidateForAccountChange() async
    func configurationDidChange() async
}
