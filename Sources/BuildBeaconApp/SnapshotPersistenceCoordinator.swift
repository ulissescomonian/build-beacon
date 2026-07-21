import BuildBeaconKit
import Foundation
import OSLog

/// Persists only the typed, non-credential pipeline facts that are useful for
/// local history. Persistence is deliberately best-effort: a disk failure must
/// never delay monitoring publication or make the interface unavailable.
actor SnapshotPersistenceCoordinator {
    private let historyStore: any PipelineHistoryStore
    private let configurationStore: any ConfigurationStore

    init(
        historyStore: any PipelineHistoryStore,
        configurationStore: any ConfigurationStore
    ) {
        self.historyStore = historyStore
        self.configurationStore = configurationStore
    }

    func persist(_ snapshot: MonitoringSnapshot) async {
        guard (try? await configurationStore.load().historyEnabled) == true else { return }
        for observation in snapshot.observations.values where observation.lastKnownRun != nil {
            do {
                try await historyStore.record(observation: observation, at: snapshot.completedAt)
            } catch {
                BuildBeaconLog.monitoring.error("Unable to persist pipeline history: \(LogRedactor.redact(error.localizedDescription), privacy: .private)")
            }
        }
    }

    func entries(for monitorID: MonitorID) async -> [PipelineHistoryEntry] {
        do {
            return try await historyStore.entries(for: monitorID, at: .now)
        } catch {
            BuildBeaconLog.monitoring.error("Unable to load pipeline history: \(LogRedactor.redact(error.localizedDescription), privacy: .private)")
            return []
        }
    }

    func removeEntries(for monitorID: MonitorID) async {
        do {
            try await historyStore.remove(for: monitorID)
        } catch {
            BuildBeaconLog.monitoring.error("Unable to remove pipeline history: \(LogRedactor.redact(error.localizedDescription), privacy: .private)")
        }
    }

    func reset() async {
        do {
            try await historyStore.reset()
        } catch {
            BuildBeaconLog.monitoring.error("Unable to clear pipeline history: \(LogRedactor.redact(error.localizedDescription), privacy: .private)")
        }
    }

    func removeAll(for accountID: AccountID) async {
        do {
            try await historyStore.removeAll(for: accountID)
        } catch {
            BuildBeaconLog.monitoring.error("Unable to remove account pipeline history: \(LogRedactor.redact(error.localizedDescription), privacy: .private)")
        }
    }
}
