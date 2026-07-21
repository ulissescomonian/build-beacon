import Foundation

public struct SnapshotDiff: Hashable, Sendable {
    public struct Change: Hashable, Sendable {
        public let monitorID: MonitorID
        public let previous: MonitorObservation
        public let current: MonitorObservation

        public init(monitorID: MonitorID, previous: MonitorObservation, current: MonitorObservation) {
            self.monitorID = monitorID
            self.previous = previous
            self.current = current
        }
    }

    public let added: [MonitorID: MonitorObservation]
    public let removed: [MonitorID: MonitorObservation]
    public let changed: [Change]
    public let aggregateStateChanged: Bool

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !aggregateStateChanged
    }

    public init(previous: MonitoringSnapshot?, current: MonitoringSnapshot) {
        guard let previous else {
            added = current.observations
            removed = [:]
            changed = []
            aggregateStateChanged = false
            return
        }

        let previousIDs = Set(previous.observations.keys)
        let currentIDs = Set(current.observations.keys)
        added = current.observations.filter { !previousIDs.contains($0.key) }
        removed = previous.observations.filter { !currentIDs.contains($0.key) }
        changed = previousIDs.intersection(currentIDs)
            .compactMap { id in
                guard let old = previous.observations[id],
                      let new = current.observations[id], old != new else { return nil }
                return Change(monitorID: id, previous: old, current: new)
            }
            .sorted { Self.stableKey($0.monitorID) < Self.stableKey($1.monitorID) }
        aggregateStateChanged = previous.aggregateState != current.aggregateState
    }

    private static func stableKey(_ id: MonitorID) -> String {
        "\(id.accountID.rawValue)/\(id.workspaceID.rawValue)/\(id.repositoryID.rawValue)/\(id.target.displayName)"
    }
}
