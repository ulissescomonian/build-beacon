import Foundation

public struct NotificationLedgerEntry: Hashable, Codable, Sendable {
    public let monitorID: MonitorID
    public let runID: PipelineRunID?
    public let kind: NotificationEventKind
    public let recordedAt: Date

    public init(
        monitorID: MonitorID,
        runID: PipelineRunID?,
        kind: NotificationEventKind,
        recordedAt: Date
    ) {
        self.monitorID = monitorID
        self.runID = runID
        self.kind = kind
        self.recordedAt = recordedAt
    }

    fileprivate var identity: Identity {
        Identity(monitorID: monitorID, runID: runID, kind: kind)
    }
}

public enum NotificationLedgerError: Error, Equatable, Sendable {
    case corrupted(quarantineURL: URL)
    case fileSystem(code: Int)
}

/// A bounded, sanitized ledger used to suppress duplicate notifications after
/// relaunches. It stores only internal IDs, transition kind and timestamp.
public actor NotificationLedger {
    public static let defaultFileName = "notification-ledger.json"

    public let fileURL: URL
    public let retentionInterval: TimeInterval
    public let maximumEntryCount: Int

    private let fileManager: FileManager
    private var entries: [NotificationLedgerEntry]?

    public init(
        fileURL: URL,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumEntryCount: Int = 500,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(0, retentionInterval)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
    }

    public init(
        applicationSupportDirectory: URL? = nil,
        directoryName: String = "BuildBeacon",
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumEntryCount: Int = 500,
        fileManager: FileManager = .default
    ) throws {
        let baseURL: URL
        if let applicationSupportDirectory {
            baseURL = applicationSupportDirectory
        } else {
            guard let resolved = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw NotificationLedgerError.fileSystem(code: NSFileNoSuchFileError)
            }
            baseURL = resolved
        }
        self.fileURL = baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(Self.defaultFileName, isDirectory: false)
        self.retentionInterval = max(0, retentionInterval)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
    }

    public func contains(_ event: NotificationEvent, at date: Date = .now) throws -> Bool {
        try loadIfNeeded(now: date)
        let identity = Identity(event: event)
        return entries?.contains(where: { $0.identity == identity }) == true
    }

    public func record(_ event: NotificationEvent, at date: Date = .now) throws {
        try loadIfNeeded(now: date)
        let identity = Identity(event: event)
        guard entries?.contains(where: { $0.identity == identity }) != true else { return }

        let previousEntries = entries
        entries?.append(
            NotificationLedgerEntry(
                monitorID: event.monitorID,
                runID: event.runID,
                kind: event.kind,
                recordedAt: date
            )
        )
        prune(now: date)
        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    public func remove(for monitorID: MonitorID, at date: Date = .now) throws {
        try loadIfNeeded(now: date)
        let previousEntries = entries
        entries?.removeAll(where: { $0.monitorID == monitorID })
        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    public func reset() throws {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            entries = []
        } catch let error as NSError {
            throw NotificationLedgerError.fileSystem(code: error.code)
        }
    }

    public func allEntries(at date: Date = .now) throws -> [NotificationLedgerEntry] {
        try loadIfNeeded(now: date)
        return entries ?? []
    }

    private func loadIfNeeded(now: Date) throws {
        guard entries == nil else {
            prune(now: now)
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let envelope = try decoder().decode(LedgerEnvelope.self, from: data)
            guard envelope.schemaVersion == LedgerEnvelope.currentSchemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            entries = envelope.entries
            prune(now: now)
        } catch {
            let quarantineURL = uniqueQuarantineURL()
            do {
                try fileManager.moveItem(at: fileURL, to: quarantineURL)
                entries = nil
                throw NotificationLedgerError.corrupted(quarantineURL: quarantineURL)
            } catch let ledgerError as NotificationLedgerError {
                throw ledgerError
            } catch let fileError as NSError {
                throw NotificationLedgerError.fileSystem(code: fileError.code)
            }
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        entries?.removeAll(where: { $0.recordedAt < cutoff })
        if let count = entries?.count, count > maximumEntryCount {
            entries?.sort(by: { $0.recordedAt < $1.recordedAt })
            entries?.removeFirst(count - maximumEntryCount)
        }
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path
            )
            let data = try encoder().encode(LedgerEnvelope(entries: entries ?? []))
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as NSError {
            throw NotificationLedgerError.fileSystem(code: error.code)
        }
    }

    private func uniqueQuarantineURL() -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString.lowercased())"
        )
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
}

private struct Identity: Hashable {
    let monitorID: MonitorID
    let runID: PipelineRunID?
    let kind: NotificationEventKind

    init(monitorID: MonitorID, runID: PipelineRunID?, kind: NotificationEventKind) {
        self.monitorID = monitorID
        self.runID = runID
        self.kind = kind
    }

    init(event: NotificationEvent) {
        self.init(monitorID: event.monitorID, runID: event.runID, kind: event.kind)
    }
}

private struct LedgerEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let entries: [NotificationLedgerEntry]

    init(entries: [NotificationLedgerEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }
}
