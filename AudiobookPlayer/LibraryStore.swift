import Foundation

protocol LibrarySyncing: AnyObject {
    func fetchRemoteCollections() async throws -> [AudiobookCollection]
    func saveRemoteCollection(_ collection: AudiobookCollection) async throws
    func deleteRemoteCollection(withID id: UUID) async throws
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var collections: [AudiobookCollection] = []
    @Published private(set) var lastError: Error?
    @Published private(set) var isLoading = false

    private let persistence: LibraryPersistence
    private let syncEngine: LibrarySyncing?
    private let schemaVersion = 3

    init(
        persistence: LibraryPersistence = .default,
        autoLoadOnInit: Bool = true,
        syncEngine: LibrarySyncing? = LibraryStore.makeDefaultSyncEngine()
    ) {
        self.persistence = persistence
        self.syncEngine = syncEngine
        if autoLoadOnInit {
            Task(priority: .userInitiated) {
                await load()
            }
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let file = try await persistence.load()
            guard file.schemaVersion <= schemaVersion else {
                throw LibraryStoreError.unsupportedSchema(file.schemaVersion)
            }

            collections = file.collections.sorted { $0.updatedAt > $1.updatedAt }
            lastError = nil

            if file.schemaVersion < schemaVersion {
                persistCurrentSnapshot()
            }

            if let syncEngine {
                await synchronizeWithRemote(using: syncEngine)
            }
        } catch {
            collections = []
            lastError = error
        }
    }

    func save(_ collection: AudiobookCollection) {
        var updated = collections
        if let index = updated.firstIndex(where: { $0.id == collection.id }) {
            updated[index] = collection
        } else {
            updated.append(collection)
        }

        collections = updated.sorted { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func delete(_ collection: AudiobookCollection) {
        collections.removeAll { $0.id == collection.id }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.deleteRemoteCollection(withID: collection.id)
            }
        }
    }

    func collection(forPath path: String) -> AudiobookCollection? {
        collections.first { collection in
            guard case let .baiduNetdisk(folderPath, _) = collection.source else {
                return false
            }
            return folderPath == path
        }
    }

    func clearErrors() {
        lastError = nil
    }

    func recordPlaybackProgress(
        collectionID: UUID,
        trackID: UUID,
        position: TimeInterval,
        duration: TimeInterval?
    ) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }

        var collection = collections[index]
        let now = Date()
        var state = collection.playbackStates[trackID] ?? TrackPlaybackState(position: 0, duration: duration, updatedAt: now)
        let clampedPosition = max(0, position)
        let didChangePosition = abs(state.position - clampedPosition) >= 5
        let didChangeDuration: Bool

        if let duration {
            if let existingDuration = state.duration {
                didChangeDuration = abs(existingDuration - duration) >= 1
            } else {
                didChangeDuration = true
            }
            state.duration = duration
        } else {
            didChangeDuration = false
        }

        if !didChangePosition && !didChangeDuration && collection.lastPlayedTrackId == trackID {
            return
        }

        state.position = clampedPosition
        state.updatedAt = now
        collection.playbackStates[trackID] = state
        collection.lastPlayedTrackId = trackID
        collection.updatedAt = now

        collections[index] = collection
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    // MARK: - Track Management (Phase 2)

    func addTracksToCollection(
        collectionID: UUID,
        newTracks: [AudiobookTrack]
    ) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        var collection = collections[index]
        let existingIds = Set(collection.tracks.map { $0.id })
        let tracksToAdd = newTracks.filter { !existingIds.contains($0.id) }

        guard !tracksToAdd.isEmpty else {
            return
        }

        collection.tracks.append(contentsOf: tracksToAdd)
        collection.updatedAt = Date()

        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func removeTrackFromCollection(
        collectionID: UUID,
        trackID: UUID
    ) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        var collection = collections[index]
        let originalCount = collection.tracks.count

        collection.tracks.removeAll { $0.id == trackID }

        guard collection.tracks.count < originalCount else {
            return
        }

        collection.playbackStates.removeValue(forKey: trackID)
        collection.updatedAt = Date()

        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func renameCollection(
        collectionID: UUID,
        newTitle: String
    ) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let clamped = String(trimmed.prefix(256))

        var collection = collections[index]
        guard collection.title != clamped else { return }

        collection.title = clamped
        collection.updatedAt = Date()

        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func renameTrack(
        in collectionID: UUID,
        trackID: UUID,
        newTitle: String
    ) {
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let clamped = String(trimmed.prefix(256))

        var collection = collections[collectionIndex]
        guard let trackIndex = collection.tracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        var track = collection.tracks[trackIndex]
        guard track.displayName != clamped else { return }

        track.displayName = clamped
        collection.tracks[trackIndex] = track
        collection.updatedAt = Date()

        collections[collectionIndex] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func canModifyCollection(_ collectionID: UUID) -> Bool {
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            return false
        }

        switch collection.source {
        case .local:
            return true
        case .baiduNetdisk:
            return true
        case .external:
            return false
        }
    }
    
    // MARK: - Favorite Management
    
    func toggleFavorite(for trackID: UUID, in collectionID: UUID) {
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard let trackIndex = collections[collectionIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        var collection = collections[collectionIndex]
        var track = collection.tracks[trackIndex]
        
        track.isFavorite.toggle()
        track.favoritedAt = track.isFavorite ? Date() : nil
        
        collection.tracks[trackIndex] = track
        collection.updatedAt = Date()
        
        collections[collectionIndex] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()
        
        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }
}

extension LibraryStore {
    struct FavoriteTrackEntry: Identifiable, Equatable {
        let collection: AudiobookCollection
        let track: AudiobookTrack
        
        var id: UUID { track.id }
    }
    
    struct FavoriteTracksGroup: Identifiable, Equatable {
        let collection: AudiobookCollection
        let tracks: [AudiobookTrack]
        
        var id: UUID { collection.id }
    }
    
    func favoriteTracks() -> [AudiobookTrack] {
        collections
            .flatMap { $0.tracks.filter(\.isFavorite) }
            .sorted { ($0.favoritedAt ?? .distantPast) > ($1.favoritedAt ?? .distantPast) }
    }
    
    func favoriteTrackEntries() -> [FavoriteTrackEntry] {
        collections.flatMap { collection in
            collection.tracks
                .filter(\.isFavorite)
                .map { FavoriteTrackEntry(collection: collection, track: $0) }
        }
        .sorted { ($0.track.favoritedAt ?? .distantPast) > ($1.track.favoritedAt ?? .distantPast) }
    }
    
    func favoriteTracksByCollection() -> [FavoriteTracksGroup] {
        collections.compactMap { collection in
            let favorites = collection.tracks.filter(\.isFavorite)
            guard !favorites.isEmpty else { return nil }
            let sortedFavorites = favorites.sorted {
                ($0.favoritedAt ?? .distantPast) > ($1.favoritedAt ?? .distantPast)
            }
            return FavoriteTracksGroup(collection: collection, tracks: sortedFavorites)
        }
    }

    private func persistCurrentSnapshot() {
        let snapshot = LibraryFile(schemaVersion: schemaVersion, collections: collections)
        Task(priority: .utility) {
            do {
                try await persistence.save(snapshot)
            } catch {
                await MainActor.run {
                    self.lastError = error
                }
            }
        }
    }
}

enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Library schema version \(version) is not supported."
        }
    }
}

struct LibraryFile: Codable {
    var schemaVersion: Int
    var collections: [AudiobookCollection]
}

private extension LibraryStore {
    nonisolated static func makeDefaultSyncEngine() -> LibrarySyncing? {
#if canImport(CloudKit)
        let info = Bundle.main.infoDictionary ?? [:]
        let isEnabled = info["CloudKitSyncEnabled"] as? Bool ?? false
        guard isEnabled else { return nil }
        return CloudKitLibrarySync.shared
#else
        return nil
#endif
    }

    func synchronizeWithRemote(using syncEngine: LibrarySyncing) async {
        do {
            let remoteCollections = try await syncEngine.fetchRemoteCollections()
            let merged = await mergeLocalCollections(
                currentCollections: collections,
                remoteCollections: remoteCollections,
                syncEngine: syncEngine
            )

            if merged != collections {
                collections = merged
                persistCurrentSnapshot()
            }
        } catch {
            // Ignore sync errors for now; local data remains authoritative offline.
        }
    }

    func mergeLocalCollections(
        currentCollections: [AudiobookCollection],
        remoteCollections: [AudiobookCollection],
        syncEngine: LibrarySyncing
    ) async -> [AudiobookCollection] {
        var merged = Dictionary(uniqueKeysWithValues: currentCollections.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCollections.map { ($0.id, $0) })

        await withTaskGroup(of: Void.self) { group in
            for (id, remote) in remoteByID {
                if let local = merged[id] {
                    if remote.updatedAt > local.updatedAt {
                        merged[id] = remote
                    } else if local.updatedAt > remote.updatedAt {
                        group.addTask {
                            try? await syncEngine.saveRemoteCollection(local)
                        }
                    }
                } else {
                    merged[id] = remote
                }
            }

            for (id, local) in merged where remoteByID[id] == nil {
                group.addTask {
                    try? await syncEngine.saveRemoteCollection(local)
                }
            }
        }

        return merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}


actor LibraryPersistence {
    static let `default` = LibraryPersistence()

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? LibraryPersistence.makeDefaultURL(fileManager: fileManager)
    }

    func load() throws -> LibraryFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LibraryFile(schemaVersion: 1, collections: [])
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryFile.self, from: data)
    }

    func save(_ file: LibraryFile) throws {
        ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(file)

        let tempURL = fileURL.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        try fileManager.moveItem(at: tempURL, to: fileURL)
    }

    private func ensureDirectoryExists() {
        let directoryURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func makeDefaultURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}
