import Foundation
import Compression

/// Coordinates export/import of user libraries, settings, and optional credentials.
final class UserDataBackupManager {
    struct ExportOptions {
        let includeCredentials: Bool
    }

    struct ExportResult {
        let archiveURL: URL
        let manifest: BackupManifest
    }

    struct ImportResult {
        let manifest: BackupManifest
        let restoredCredentials: CredentialRestoreSummary
        let appliedSettings: SettingsSnapshot?
    }

    struct BackupManifest: Codable {
        struct Counts: Codable {
            let collections: Int
            let tracks: Int
            let favorites: Int
            let transcripts: Int
        }

        let schemaVersion: Int
        let exportedAt: Date
        let appVersion: String?
        let buildNumber: String?
        let includeCredentials: Bool
        let counts: Counts
    }

    struct PlaybackStateSnapshot: Codable {
        struct CollectionEntry: Codable {
            struct TrackEntry: Codable {
                let trackId: UUID
                let isFavorite: Bool
                let position: TimeInterval
                let duration: TimeInterval?
                let updatedAt: Date
            }

            let collectionId: UUID
            let title: String
            let lastPlayedTrackId: UUID?
            let tracks: [TrackEntry]
        }

        let entries: [CollectionEntry]
    }

    struct SettingsSnapshot: Codable {
        var cacheTTLDays: Int
        var aiDefaultModel: String?
        var aiTabModelsExpanded: Bool
        var aiTabCollapsedProviders: [String]
    }

    struct CredentialBlob: Codable {
        let value: String
        let savedAt: Date
    }

    struct CredentialRestoreSummary: Codable {
        let aiGateway: Bool
        let soniox: Bool
        let baidu: Bool
    }

    enum BackupError: LocalizedError {
        case manifestMissing
        case manifestUnsupported(Int)
        case databaseMissing
        case archiveCorrupt(String)

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "Backup manifest is missing or unreadable."
            case .manifestUnsupported(let version):
                return "This backup was created with a newer version (schema \(version)). Update the app and try again."
            case .databaseMissing:
                return "Database payload missing from archive."
            case .archiveCorrupt(let detail):
                return "Backup archive is corrupted: \(detail)."
            }
        }
    }

    private enum Constants {
        static let schemaVersion = 1
        static let archiveExtension = "happybear-export.zip"
        static let manifestFile = "manifest.json"
        static let databaseDirectory = "database"
        static let metadataDirectory = "metadata"
        static let credentialsDirectory = "credentials"
        static let libraryFileName = "library.sqlite"
        static let playbackFileName = "playback_state.json"
        static let settingsFileName = "settings.json"
        static let aiCredentialFile = "ai_gateway.json"
        static let sonioxCredentialFile = "soniox.json"
        static let baiduCredentialFile = "baidu_oauth.json"
        static let cacheTTLKey = "AudioCacheRetainedDays"
        static let aiDefaultModelKey = "ai_gateway_default_model"
        static let aiModelsExpandedKey = "ai_tab_models_section_expanded_v2"
        static let aiCollapsedProvidersKey = "ai_tab_collapsed_provider_data_v2"
    }

    private let dbManager: GRDBDatabaseManager
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let aiKeyStore: AIGatewayAPIKeyStore
    private let sonioxKeyStore: SonioxAPIKeyStore
    private let baiduTokenStore: BaiduOAuthTokenStore

    init(
        dbManager: GRDBDatabaseManager = .shared,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        aiKeyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore(),
        sonioxKeyStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore(),
        baiduTokenStore: BaiduOAuthTokenStore = KeychainBaiduOAuthTokenStore()
    ) {
        self.dbManager = dbManager
        self.fileManager = fileManager
        self.defaults = defaults
        self.aiKeyStore = aiKeyStore
        self.sonioxKeyStore = sonioxKeyStore
        self.baiduTokenStore = baiduTokenStore
    }

    // MARK: - Export

    func exportUserData(
        library: LibraryStore,
        options: ExportOptions
    ) async throws -> ExportResult {
        let workingDirectory = try makeWorkingDirectory(prefix: "HappyBear-Export")
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let databaseDir = workingDirectory.appendingPathComponent(Constants.databaseDirectory, isDirectory: true)
        let metadataDir = workingDirectory.appendingPathComponent(Constants.metadataDirectory, isDirectory: true)
        let credentialsDir = workingDirectory.appendingPathComponent(Constants.credentialsDirectory, isDirectory: true)

        try fileManager.createDirectory(at: databaseDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: credentialsDir, withIntermediateDirectories: true)

        let databaseDestination = databaseDir.appendingPathComponent(Constants.libraryFileName)
        try dbManager.exportDatabaseSnapshot(to: databaseDestination)

        let collections = await MainActor.run { library.collections }
        let playbackSnapshot = makePlaybackSnapshot(from: collections)
        try writeJSON(playbackSnapshot, to: metadataDir.appendingPathComponent(Constants.playbackFileName))

        let settingsSnapshot = captureSettingsSnapshot()
        try writeJSON(settingsSnapshot, to: metadataDir.appendingPathComponent(Constants.settingsFileName))

        let credentialSummary = try writeCredentialPayloads(
            to: credentialsDir,
            includeCredentials: options.includeCredentials
        )

        let stats = try dbManager.fetchTranscriptionStats()
        let manifest = BackupManifest(
            schemaVersion: Constants.schemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            includeCredentials: options.includeCredentials && (credentialSummary.aiGateway || credentialSummary.soniox || credentialSummary.baidu),
            counts: .init(
                collections: collections.count,
                tracks: collections.reduce(into: 0) { $0 += $1.tracks.count },
                favorites: collections.reduce(into: 0) { partialResult, collection in
                    partialResult += collection.tracks.filter { $0.isFavorite }.count
                },
                transcripts: stats.transcripts
            )
        )
        try writeJSON(manifest, to: workingDirectory.appendingPathComponent(Constants.manifestFile))

        let archiveURL = makeArchiveURL()
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.zipItem(at: workingDirectory, to: archiveURL, shouldKeepParent: false, compressionMethod: .deflate)

        return ExportResult(archiveURL: archiveURL, manifest: manifest)
    }

    // MARK: - Import

    func importUserData(from archiveURL: URL) async throws -> ImportResult {
        let workingDirectory = try makeWorkingDirectory(prefix: "HappyBear-Import")
        defer { try? fileManager.removeItem(at: workingDirectory) }

        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        do {
            try fileManager.unzipItem(at: archiveURL, to: workingDirectory)
        } catch {
            throw BackupError.archiveCorrupt(error.localizedDescription)
        }

        let manifestURL = workingDirectory.appendingPathComponent(Constants.manifestFile)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BackupError.manifestMissing
        }
        let manifest = try readJSON(BackupManifest.self, from: manifestURL)
        guard manifest.schemaVersion <= Constants.schemaVersion else {
            throw BackupError.manifestUnsupported(manifest.schemaVersion)
        }

        let dbSource = workingDirectory
            .appendingPathComponent(Constants.databaseDirectory)
            .appendingPathComponent(Constants.libraryFileName)
        guard fileManager.fileExists(atPath: dbSource.path) else {
            throw BackupError.databaseMissing
        }

        try dbManager.replaceDatabase(with: dbSource)
        try dbManager.initializeDatabase()

        let settingsURL = workingDirectory
            .appendingPathComponent(Constants.metadataDirectory)
            .appendingPathComponent(Constants.settingsFileName)
        let appliedSettings = try? readJSON(SettingsSnapshot.self, from: settingsURL)
        if let snapshot = appliedSettings {
            applySettingsSnapshot(snapshot)
        }

        let credentialsDir = workingDirectory.appendingPathComponent(Constants.credentialsDirectory)
        let restoreSummary = try restoreCredentials(from: credentialsDir)

        return ImportResult(manifest: manifest, restoredCredentials: restoreSummary, appliedSettings: appliedSettings)
    }

    // MARK: - Helpers

    private func makeWorkingDirectory(prefix: String) throws -> URL {
        let base = fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeArchiveURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return fileManager.temporaryDirectory
            .appendingPathComponent("HappyBear-Backup-\(timestamp).\(Constants.archiveExtension)")
    }

    private func makePlaybackSnapshot(from collections: [AudiobookCollection]) -> PlaybackStateSnapshot {
        let entries = collections.map { collection -> PlaybackStateSnapshot.CollectionEntry in
            let trackEntries = collection.playbackStates.map { key, state in
                let isFavorite = collection.tracks.first(where: { $0.id == key })?.isFavorite ?? false
                return PlaybackStateSnapshot.CollectionEntry.TrackEntry(
                    trackId: key,
                    isFavorite: isFavorite,
                    position: state.position,
                    duration: state.duration,
                    updatedAt: state.updatedAt
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }

            return PlaybackStateSnapshot.CollectionEntry(
                collectionId: collection.id,
                title: collection.title,
                lastPlayedTrackId: collection.lastPlayedTrackId,
                tracks: trackEntries
            )
        }
        return PlaybackStateSnapshot(entries: entries)
    }

    private func captureSettingsSnapshot() -> SettingsSnapshot {
        let ttl = defaults.integer(forKey: Constants.cacheTTLKey)
        let collapsedData = defaults.data(forKey: Constants.aiCollapsedProvidersKey) ?? Data()
        let collapsedProviders: [String]
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: collapsedData) {
            collapsedProviders = Array(decoded).sorted()
        } else {
            collapsedProviders = []
        }

        return SettingsSnapshot(
            cacheTTLDays: ttl > 0 ? ttl : 10,
            aiDefaultModel: defaults.string(forKey: Constants.aiDefaultModelKey),
            aiTabModelsExpanded: defaults.object(forKey: Constants.aiModelsExpandedKey) as? Bool ?? true,
            aiTabCollapsedProviders: collapsedProviders
        )
    }

    private func applySettingsSnapshot(_ snapshot: SettingsSnapshot) {
        defaults.set(snapshot.cacheTTLDays, forKey: Constants.cacheTTLKey)
        if let model = snapshot.aiDefaultModel {
            defaults.set(model, forKey: Constants.aiDefaultModelKey)
        } else {
            defaults.removeObject(forKey: Constants.aiDefaultModelKey)
        }
        defaults.set(snapshot.aiTabModelsExpanded, forKey: Constants.aiModelsExpandedKey)

        let collapsedSet = Set(snapshot.aiTabCollapsedProviders)
        if let data = try? JSONEncoder().encode(collapsedSet) {
            defaults.set(data, forKey: Constants.aiCollapsedProvidersKey)
        }
    }

    private func writeCredentialPayloads(
        to directory: URL,
        includeCredentials: Bool
    ) throws -> CredentialRestoreSummary {
        guard includeCredentials else {
            return CredentialRestoreSummary(aiGateway: false, soniox: false, baidu: false)
        }

        var aiWritten = false
        if let loadedKey = try? aiKeyStore.loadKey(), let keyValue = loadedKey, !keyValue.isEmpty {
            let blob = CredentialBlob(value: keyValue, savedAt: Date())
            try writeJSON(blob, to: directory.appendingPathComponent(Constants.aiCredentialFile))
            aiWritten = true
        }

        var sonioxWritten = false
        if let loadedKey = try? sonioxKeyStore.loadKey(), let keyValue = loadedKey, !keyValue.isEmpty {
            let blob = CredentialBlob(value: keyValue, savedAt: Date())
            try writeJSON(blob, to: directory.appendingPathComponent(Constants.sonioxCredentialFile))
            sonioxWritten = true
        }

        var baiduWritten = false
        if let loadedToken = try? baiduTokenStore.loadToken(), let token = loadedToken {
            try writeJSON(token, to: directory.appendingPathComponent(Constants.baiduCredentialFile))
            baiduWritten = true
        }

        return CredentialRestoreSummary(aiGateway: aiWritten, soniox: sonioxWritten, baidu: baiduWritten)
    }

    private func restoreCredentials(from directory: URL) throws -> CredentialRestoreSummary {
        guard fileManager.fileExists(atPath: directory.path) else {
            return CredentialRestoreSummary(aiGateway: false, soniox: false, baidu: false)
        }

        var aiRestored = false
        var sonioxRestored = false
        var baiduRestored = false

        let aiURL = directory.appendingPathComponent(Constants.aiCredentialFile)
        if fileManager.fileExists(atPath: aiURL.path) {
            let blob = try readJSON(CredentialBlob.self, from: aiURL)
            try aiKeyStore.saveKey(blob.value)
            aiRestored = true
        }

        let sonioxURL = directory.appendingPathComponent(Constants.sonioxCredentialFile)
        if fileManager.fileExists(atPath: sonioxURL.path) {
            let blob = try readJSON(CredentialBlob.self, from: sonioxURL)
            try sonioxKeyStore.saveKey(blob.value)
            sonioxRestored = true
        }

        let baiduURL = directory.appendingPathComponent(Constants.baiduCredentialFile)
        if fileManager.fileExists(atPath: baiduURL.path) {
            let token = try readJSON(BaiduOAuthToken.self, from: baiduURL)
            try baiduTokenStore.saveToken(token)
            baiduRestored = true
        }

        return CredentialRestoreSummary(aiGateway: aiRestored, soniox: sonioxRestored, baidu: baiduRestored)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
