import Foundation

public enum PipelineHistoryStoreError: Error, Equatable, Sendable {
    case corrupted(quarantineURL: URL)
    case unsupportedSchema(found: Int, supported: Int)
    case recoveryRequired
    case fileSystem(code: Int)
}

/// A bounded, local-only record of the most recent pipeline runs per monitor.
///
/// The stored entry intentionally contains only run identity, status and timing.
/// It never writes repository names, slugs, branches, commit hashes, failure text,
/// steps, URLs, credentials, API payloads or request metadata to disk.
public actor JSONPipelineHistoryStore: PipelineHistoryStore {
    public static let defaultFileName = "pipeline-history.json"
    public static let currentSchemaVersion = 1

    public let fileURL: URL
    public let maximumRunsPerMonitor: Int
    public let retentionInterval: TimeInterval
    public let maximumEntryCount: Int

    private let fileManager: FileManager
    private var cachedEntries: [PipelineHistoryEntry]?
    private var recoveryRequired = false

    public init(
        fileURL: URL,
        maximumRunsPerMonitor: Int = 20,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumEntryCount: Int = 500,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumRunsPerMonitor = max(1, maximumRunsPerMonitor)
        self.retentionInterval = max(0, retentionInterval)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
    }

    public init(
        applicationSupportDirectory: URL? = nil,
        directoryName: String = "BuildBeacon",
        maximumRunsPerMonitor: Int = 20,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumEntryCount: Int = 500,
        fileManager: FileManager = .default
    ) throws {
        let baseURL: URL
        if let applicationSupportDirectory {
            baseURL = applicationSupportDirectory
        } else {
            guard let resolved = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw PipelineHistoryStoreError.fileSystem(code: NSFileNoSuchFileError)
            }
            baseURL = resolved
        }

        self.fileURL = baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(Self.defaultFileName, isDirectory: false)
        self.maximumRunsPerMonitor = max(1, maximumRunsPerMonitor)
        self.retentionInterval = max(0, retentionInterval)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
    }

    public func record(observation: MonitorObservation, at date: Date = .now) async throws {
        guard observation.currentFailure == nil, let run = observation.lastKnownRun else { return }
        try loadIfNeeded(now: date)

        let entry = PipelineHistoryEntry(
            monitorID: observation.monitor.id,
            runID: run.id,
            buildNumber: run.buildNumber,
            phase: run.phase,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            observedAt: date
        )
        var next = cachedEntries ?? []
        if let index = next.firstIndex(where: {
            $0.monitorID == entry.monitorID && $0.runID == entry.runID
        }) {
            let previous = next[index]
            next[index] = PipelineHistoryEntry(
                monitorID: entry.monitorID,
                runID: entry.runID,
                buildNumber: entry.buildNumber,
                phase: entry.phase,
                startedAt: entry.startedAt ?? previous.startedAt,
                completedAt: entry.completedAt ?? previous.completedAt,
                observedAt: entry.observedAt
            )
        } else {
            next.append(entry)
        }
        try replaceEntries(with: next, now: date)
    }

    public func entries(for monitorID: MonitorID, at date: Date = .now) async throws -> [PipelineHistoryEntry] {
        try loadIfNeeded(now: date)
        try persistPrunedEntriesIfNeeded(now: date)
        return (cachedEntries ?? [])
            .filter { $0.monitorID == monitorID }
            .sorted(by: Self.isNewer)
    }

    public func remove(for monitorID: MonitorID) async throws {
        try loadIfNeeded(now: .now)
        try replaceEntries(with: (cachedEntries ?? []).filter { $0.monitorID != monitorID }, now: .now)
    }

    public func removeAll(for accountID: AccountID) async throws {
        try loadIfNeeded(now: .now)
        try replaceEntries(
            with: (cachedEntries ?? []).filter { $0.monitorID.accountID != accountID },
            now: .now
        )
    }

    public func reset() async throws {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            cachedEntries = []
            recoveryRequired = false
        } catch let error as NSError {
            throw PipelineHistoryStoreError.fileSystem(code: error.code)
        }
    }

    private func loadIfNeeded(now: Date) throws {
        guard !recoveryRequired else {
            throw PipelineHistoryStoreError.recoveryRequired
        }
        guard cachedEntries == nil else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedEntries = []
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as NSError {
            throw PipelineHistoryStoreError.fileSystem(code: error.code)
        }

        guard let schemaVersion = schemaVersion(in: data) else {
            try quarantineCorruptedFile()
            return
        }
        if schemaVersion > Self.currentSchemaVersion {
            recoveryRequired = true
            throw PipelineHistoryStoreError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        do {
            let envelope = try decoder().decode(HistoryEnvelope.self, from: data)
            if envelope.schemaVersion == Self.currentSchemaVersion {
                cachedEntries = normalized(envelope.entries, now: now)
                recoveryRequired = false
            } else {
                try migrate(envelope: envelope, detectedVersion: envelope.schemaVersion, now: now)
            }
        } catch let error as PipelineHistoryStoreError {
            throw error
        } catch {
            try quarantineCorruptedFile()
        }
    }

    private func migrate(envelope: HistoryEnvelope, detectedVersion: Int, now: Date) throws {
        guard detectedVersion == 0 else {
            recoveryRequired = true
            throw PipelineHistoryStoreError.recoveryRequired
        }
        try backup(suffix: "v0")
        cachedEntries = normalized(envelope.entries, now: now)
        try persist()
        recoveryRequired = false
    }

    private func replaceEntries(with entries: [PipelineHistoryEntry], now: Date) throws {
        guard !recoveryRequired else { throw PipelineHistoryStoreError.recoveryRequired }
        let previous = cachedEntries
        cachedEntries = normalized(entries, now: now)
        guard cachedEntries != previous else { return }
        do {
            try persist()
        } catch {
            cachedEntries = previous
            throw error
        }
    }

    private func persistPrunedEntriesIfNeeded(now: Date) throws {
        let previous = cachedEntries
        cachedEntries = normalized(cachedEntries ?? [], now: now)
        guard cachedEntries != previous else { return }
        do {
            try persist()
        } catch {
            cachedEntries = previous
            throw error
        }
    }

    private func normalized(_ entries: [PipelineHistoryEntry], now: Date) -> [PipelineHistoryEntry] {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        var deduplicated: [PipelineHistoryEntry] = []
        for entry in entries.sorted(by: Self.isNewer) where entry.observedAt >= cutoff {
            if !deduplicated.contains(where: {
                $0.monitorID == entry.monitorID && $0.runID == entry.runID
            }) {
                deduplicated.append(entry)
            }
        }

        var perMonitorCounts: [MonitorID: Int] = [:]
        let perMonitorBounded = deduplicated.filter { entry in
            let count = perMonitorCounts[entry.monitorID, default: 0]
            guard count < maximumRunsPerMonitor else { return false }
            perMonitorCounts[entry.monitorID] = count + 1
            return true
        }
        return Array(perMonitorBounded.prefix(maximumEntryCount))
    }

    private func persist() throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try encoder().encode(HistoryEnvelope(entries: cachedEntries ?? []))
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as NSError {
            throw PipelineHistoryStoreError.fileSystem(code: error.code)
        }
    }

    private func backup(suffix: String) throws {
        let backupURL = uniqueSiblingURL(label: "backup-\(suffix)")
        do {
            try fileManager.copyItem(at: fileURL, to: backupURL)
        } catch let error as NSError {
            throw PipelineHistoryStoreError.fileSystem(code: error.code)
        }
    }

    private func quarantineCorruptedFile() throws {
        let quarantineURL = uniqueSiblingURL(label: "corrupt")
        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            cachedEntries = nil
            recoveryRequired = true
            throw PipelineHistoryStoreError.corrupted(quarantineURL: quarantineURL)
        } catch let error as PipelineHistoryStoreError {
            throw error
        } catch let error as NSError {
            throw PipelineHistoryStoreError.fileSystem(code: error.code)
        }
    }

    private func uniqueSiblingURL(label: String) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let unique = UUID().uuidString.lowercased()
        return fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).\(label)-\(timestamp)-\(unique)"
        )
    }

    private func schemaVersion(in data: Data) -> Int? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let number = dictionary["schemaVersion"] as? NSNumber
        else { return nil }
        return number.intValue
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func isNewer(_ lhs: PipelineHistoryEntry, _ rhs: PipelineHistoryEntry) -> Bool {
        let lhsDate = lhs.completedAt ?? lhs.startedAt ?? lhs.observedAt
        let rhsDate = rhs.completedAt ?? rhs.startedAt ?? rhs.observedAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        return lhs.runID.rawValue > rhs.runID.rawValue
    }
}

private struct HistoryEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let entries: [PipelineHistoryEntry]

    init(entries: [PipelineHistoryEntry]) {
        self.schemaVersion = JSONPipelineHistoryStore.currentSchemaVersion
        self.entries = entries
    }
}
