import Foundation

public enum ConfigurationStoreError: Error, Equatable, Sendable {
    case corrupted(quarantineURL: URL)
    case unsupportedSchema(found: Int, supported: Int)
    case invalidConfiguration(reason: String)
    case recoveryRequired
    case fileSystem(code: Int)
}

/// The single source of truth for non-secret application configuration.
///
/// Writes are atomic. Corrupt or future-version files place the actor in a
/// recovery-required state, preventing an innocent save from destroying data.
public actor JSONConfigurationStore: ConfigurationStore {
    public static let defaultFileName = "configuration.json"

    public let fileURL: URL

    private let fileManager: FileManager
    private var recoveryRequired = false

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(
        applicationSupportDirectory: URL? = nil,
        directoryName: String = "BuildBeacon",
        fileManager: FileManager = .default
    ) throws {
        let baseURL: URL
        if let applicationSupportDirectory {
            baseURL = applicationSupportDirectory
        } else {
            guard let resolved = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw ConfigurationStoreError.fileSystem(code: NSFileNoSuchFileError)
            }
            baseURL = resolved
        }
        self.fileURL = baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(Self.defaultFileName, isDirectory: false)
        self.fileManager = fileManager
    }

    public func load() async throws -> AppConfiguration {
        try loadConfiguration()
    }

    private func loadConfiguration() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            recoveryRequired = false
            return AppConfiguration()
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }

        if let version = schemaVersion(in: data), version > AppConfiguration.schemaVersion {
            recoveryRequired = true
            throw ConfigurationStoreError.unsupportedSchema(
                found: version,
                supported: AppConfiguration.schemaVersion
            )
        }

        do {
            let envelope = try decoder().decode(PersistedSchemaVersion.self, from: data)
            guard envelope.schemaVersion == AppConfiguration.schemaVersion else {
                return try migrate(data: data, detectedVersion: envelope.schemaVersion)
            }
            let persisted = try decoder().decode(PersistedConfiguration.self, from: data)
            let normalized = try Self.normalized(persisted.configuration)
            recoveryRequired = false
            return normalized
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            // Version 0 was an unwrapped AppConfiguration used before the
            // versioned envelope existed.
            if let legacy = try? decoder().decode(LegacyAppConfigurationV1.self, from: data) {
                return try migrateLegacy(legacy)
            }
            let quarantineURL = try quarantineCorruptedFile()
            recoveryRequired = true
            throw ConfigurationStoreError.corrupted(quarantineURL: quarantineURL)
        }
    }

    public func save(_ configuration: AppConfiguration) async throws {
        guard !recoveryRequired else {
            throw ConfigurationStoreError.recoveryRequired
        }
        try verifyExistingFileIsSafeToOverwrite()
        let normalized = try Self.normalized(configuration)
        try write(PersistedConfiguration(configuration: normalized))
    }

    /// Atomically replaces only the activity markers for the configured
    /// account. Keeping this read-normalize-write sequence inside the actor
    /// prevents a concurrent preference save from being lost.
    public func saveUnseenActivity(
        _ markers: [MonitorActivityMarker],
        for accountID: AccountID
    ) async throws -> AppConfiguration {
        let configuration = try loadConfiguration()
        guard configuration.account?.id == accountID else {
            throw ConfigurationStoreError.invalidConfiguration(
                reason: "activity markers do not match the configured account"
            )
        }

        var updated = configuration
        updated.unseenActivity = markers
        let normalized = try Self.normalized(updated)
        try write(PersistedConfiguration(configuration: normalized))
        return normalized
    }

    public func reset() async throws {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            recoveryRequired = false
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }
    }

    private func verifyExistingFileIsSafeToOverwrite() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }

        guard let version = schemaVersion(in: data) else {
            recoveryRequired = true
            throw ConfigurationStoreError.recoveryRequired
        }
        guard version <= AppConfiguration.schemaVersion else {
            recoveryRequired = true
            throw ConfigurationStoreError.unsupportedSchema(
                found: version,
                supported: AppConfiguration.schemaVersion
            )
        }
    }

    private func migrate(data: Data, detectedVersion: Int) throws -> AppConfiguration {
        guard detectedVersion < AppConfiguration.schemaVersion else {
            recoveryRequired = true
            throw ConfigurationStoreError.unsupportedSchema(
                found: detectedVersion,
                supported: AppConfiguration.schemaVersion
            )
        }
        switch detectedVersion {
        case 2:
            let persisted = try decoder().decode(PersistedConfigurationV2.self, from: data)
            let migrated = try Self.normalized(AppConfiguration(legacyV2: persisted.configuration))
            _ = try backup(suffix: "v2")
            try write(PersistedConfiguration(configuration: migrated))
            recoveryRequired = false
            return migrated
        case 1:
            let persisted = try decoder().decode(PersistedConfigurationV1.self, from: data)
            let migrated = try Self.normalized(AppConfiguration(legacyV1: persisted.configuration))
            _ = try backup(suffix: "v1")
            try write(PersistedConfiguration(configuration: migrated))
            recoveryRequired = false
            return migrated
        default:
            // Preserve unknown historical data rather than guessing at a destructive migration.
            _ = try backup(suffix: "v\(detectedVersion)")
            recoveryRequired = true
            throw ConfigurationStoreError.recoveryRequired
        }
    }

    private func migrateLegacy(_ legacy: LegacyAppConfigurationV1) throws -> AppConfiguration {
        let normalized = try Self.normalized(AppConfiguration(legacyV1: legacy))
        _ = try backup(suffix: "v0")
        try write(PersistedConfiguration(configuration: normalized))
        recoveryRequired = false
        return normalized
    }

    private func write(_ persisted: PersistedConfiguration) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try encoder().encode(persisted)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as ConfigurationStoreError {
            throw error
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }
    }

    private func backup(suffix: String) throws -> URL {
        let backupURL = uniqueSiblingURL(label: "backup-\(suffix)")
        do {
            try fileManager.copyItem(at: fileURL, to: backupURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            return backupURL
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }
    }

    private func quarantineCorruptedFile() throws -> URL {
        let quarantineURL = uniqueSiblingURL(label: "corrupt")
        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quarantineURL.path)
            return quarantineURL
        } catch let error as NSError {
            throw ConfigurationStoreError.fileSystem(code: error.code)
        }
    }

    private func uniqueSiblingURL(label: String) -> URL {
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let unique = UUID().uuidString.lowercased()
        let name = "\(base).\(label)-\(timestamp)-\(unique)" + (ext.isEmpty ? "" : ".\(ext)")
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
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

    private static func normalized(_ configuration: AppConfiguration) throws -> AppConfiguration {
        guard (30...86_400).contains(configuration.refreshIntervalSeconds) else {
            throw ConfigurationStoreError.invalidConfiguration(
                reason: "refreshIntervalSeconds must be between 30 and 86400"
            )
        }

        var result = configuration
        var monitorIDs = Set<MonitorID>()
        result.monitors = try configuration.monitors.compactMap { monitor in
            let workspaceSlug = monitor.workspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let repositorySlug = monitor.repositorySlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !workspaceSlug.isEmpty, !repositorySlug.isEmpty else {
                throw ConfigurationStoreError.invalidConfiguration(reason: "monitor slugs must not be empty")
            }
            guard monitorIDs.insert(monitor.id).inserted else { return nil }

            var normalized = monitor
            normalized.workspaceSlug = workspaceSlug
            normalized.repositorySlug = repositorySlug
            normalized.workspaceName = monitor.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.repositoryName = monitor.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.projectName = monitor.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        let activeMonitorIDs = Set(result.monitors.map(\.id))
        var markedMonitorIDs = Set<MonitorID>()
        result.unseenActivity = configuration.unseenActivity.filter {
            activeMonitorIDs.contains($0.monitorID) && markedMonitorIDs.insert($0.monitorID).inserted
        }
        return result
    }
}

private struct PersistedConfiguration: Codable, Sendable {
    let schemaVersion: Int
    let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.schemaVersion = AppConfiguration.schemaVersion
        self.configuration = configuration
    }
}

private struct PersistedSchemaVersion: Codable, Sendable {
    let schemaVersion: Int
}

/// The explicit v2 representation preserves the exact historical payload so
/// schema 3 can add activity preferences without weakening strict current
/// schema decoding.
private struct PersistedConfigurationV2: Codable, Sendable {
    let schemaVersion: Int
    let configuration: LegacyAppConfigurationV2
}

private struct LegacyAppConfigurationV2: Codable, Sendable {
    let account: AccountProfile?
    let monitors: [MonitorConfiguration]
    let refreshIntervalSeconds: Int
    let notificationsEnabled: Bool
    let notifyOnFailure: Bool
    let notifyOnRecovery: Bool
    let notifyOnApproval: Bool
    let monitorPresentation: MonitorPresentationPreferences
    let historyEnabled: Bool
}

/// The explicit v1 representation intentionally excludes v2 presentation and
/// history preferences. This keeps migration deterministic even as v2 gains
/// additional fields in the future.
private struct PersistedConfigurationV1: Codable, Sendable {
    let schemaVersion: Int
    let configuration: LegacyAppConfigurationV1
}

private struct LegacyAppConfigurationV1: Codable, Sendable {
    let account: AccountProfile?
    let monitors: [LegacyMonitorConfigurationV1]
    let refreshIntervalSeconds: Int
    let notificationsEnabled: Bool
    let notifyOnFailure: Bool
    let notifyOnRecovery: Bool
    let notifyOnApproval: Bool
}

private struct LegacyMonitorConfigurationV1: Codable, Sendable {
    let id: MonitorID
    let workspaceSlug: String
    let workspaceName: String
    let repositorySlug: String
    let repositoryName: String
    let projectName: String?
    let isPinned: Bool
}

private extension AppConfiguration {
    init(legacyV2: LegacyAppConfigurationV2) {
        var presentation = legacyV2.monitorPresentation
        // Activity order is the intentional v3 product default, including for
        // users who already have a v2 configuration.
        presentation.sortOrder = .recentActivity
        self.init(
            account: legacyV2.account,
            monitors: legacyV2.monitors,
            refreshIntervalSeconds: legacyV2.refreshIntervalSeconds,
            notificationsEnabled: legacyV2.notificationsEnabled,
            notifyOnFailure: legacyV2.notifyOnFailure,
            notifyOnRecovery: legacyV2.notifyOnRecovery,
            notifyOnApproval: legacyV2.notifyOnApproval,
            notifyOnFavoriteSuccess: false,
            monitorPresentation: presentation,
            historyEnabled: legacyV2.historyEnabled,
            unseenActivity: []
        )
    }

    init(legacyV1: LegacyAppConfigurationV1) {
        self.init(
            account: legacyV1.account,
            monitors: legacyV1.monitors.map {
                MonitorConfiguration(
                    id: $0.id,
                    workspaceSlug: $0.workspaceSlug,
                    workspaceName: $0.workspaceName,
                    repositorySlug: $0.repositorySlug,
                    repositoryName: $0.repositoryName,
                    projectName: $0.projectName,
                    isPinned: $0.isPinned,
                    isHidden: false
                )
            },
            refreshIntervalSeconds: legacyV1.refreshIntervalSeconds,
            notificationsEnabled: legacyV1.notificationsEnabled,
            notifyOnFailure: legacyV1.notifyOnFailure,
            notifyOnRecovery: legacyV1.notifyOnRecovery,
            notifyOnApproval: legacyV1.notifyOnApproval,
            monitorPresentation: .init(),
            historyEnabled: true,
            unseenActivity: []
        )
    }
}
