import Foundation
import UIKit

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

    private let dbManager: GRDBDatabaseManager
    private let jsonPersistence: LibraryPersistence  // Keep for fallback
    private let syncEngine: LibrarySyncing?
    private let coverImageStore: CollectionCoverImageStore
    private let schemaVersion = 3

    private var useFallbackJSON = false

    init(
        dbManager: GRDBDatabaseManager = .shared,
        jsonPersistence: LibraryPersistence = .default,
        autoLoadOnInit: Bool = true,
        syncEngine: LibrarySyncing? = LibraryStore.makeDefaultSyncEngine(),
        coverImageStore: CollectionCoverImageStore = .shared
    ) {
        self.dbManager = dbManager
        self.jsonPersistence = jsonPersistence
        self.syncEngine = syncEngine
        self.coverImageStore = coverImageStore
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
            // Initialize database if not already done
            try await dbManager.initializeDatabase()

            // Load from SQLite database
            let dbCollections = try await dbManager.loadAllCollections()
            collections = dbCollections.sorted { $0.updatedAt > $1.updatedAt }

            // Debug: print favorite count
            let favoriteCount = collections.flatMap { $0.tracks }.filter { $0.isFavorite }.count
            print("[FAVORITES] Loaded \(collections.count) collections with \(favoriteCount) total favorite tracks")
            for collection in collections {
                let collectionFavorites = collection.tracks.filter { $0.isFavorite }
                if !collectionFavorites.isEmpty {
                    print("[FAVORITES]   - \(collection.title): \(collectionFavorites.count) favorites")
                }
            }

            lastError = nil

            // Sync with remote if available
            if let syncEngine {
                print("[FAVORITES] Before sync with remote: \(collections.flatMap { $0.tracks }.filter { $0.isFavorite }.count) favorites")
                await synchronizeWithRemote(using: syncEngine)
                print("[FAVORITES] After sync with remote: \(collections.flatMap { $0.tracks }.filter { $0.isFavorite }.count) favorites")
            }
        } catch {
            print("❌ Failed to load from GRDB: \(error)")


            // Fallback to JSON if GRDB fails
            do {
                print("⚠️  Attempting to load from JSON fallback...")
                let file = try await jsonPersistence.load()
                guard file.schemaVersion <= schemaVersion else {
                    throw LibraryStoreError.unsupportedSchema(file.schemaVersion)
                }

                collections = file.collections.sorted { $0.updatedAt > $1.updatedAt }
                useFallbackJSON = true
                lastError = NSError(
                    domain: "LibraryStore",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Using fallback JSON persistence. Please restart the app."]
                )
            } catch {
                collections = []
                lastError = error
            }
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

        // Persist to database
        if !useFallbackJSON {
            persistToDatabase(collection)
        } else {
            persistCurrentSnapshot()  // Fallback to JSON
        }

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func delete(_ collection: AudiobookCollection) {
        collections.removeAll { $0.id == collection.id }

        if case let .image(relativePath) = collection.coverAsset.kind {
            Task(priority: .utility) {
                try? await coverImageStore.deleteImage(at: relativePath)
            }
        }

        // Delete from database
        if !useFallbackJSON {
            deleteFromDatabase(collection.id)
        } else {
            persistCurrentSnapshot()  // Fallback to JSON
        }

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

        // Persist to database
        if !useFallbackJSON {
            Task(priority: .utility) {
                do {
                    // OPTIMIZATION: Only save playback state, not entire collection
                    // Avoid expensive DELETE+INSERT of all tracks/tags when only playback position changed
                    try await dbManager.savePlaybackState(
                        trackId: trackID,
                        collectionId: collectionID,
                        position: clampedPosition,
                        duration: duration
                    )
                    // Note: collection.updatedAt and lastPlayedTrackId updates are kept in memory
                    // but deferred from database to avoid high-frequency full collection saves
                } catch {
                    await MainActor.run {
                        self.lastError = error
                    }
                }
            }
        } else {
            persistCurrentSnapshot()  // Fallback to JSON
        }

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

        // Persist to database
        if !useFallbackJSON {
            persistToDatabase(collection)
        } else {
            persistCurrentSnapshot()
        }

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

        // Persist to database
        if !useFallbackJSON {
            Task(priority: .utility) {
                do {
                    try await dbManager.removeTrack(id: trackID, from: collectionID)
                    try await dbManager.saveCollection(collection)
                } catch {
                    await MainActor.run {
                        self.lastError = error
                    }
                }
            }
        } else {
            persistCurrentSnapshot()
        }

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
        updateCollectionDetails(
            collectionID: collectionID,
            newTitle: newTitle,
            newDescription: nil,
            shouldUpdateDescription: false
        )
    }

    func updateCollectionDetails(
        collectionID: UUID,
        newTitle: String,
        newDescription: String?,
        shouldUpdateDescription: Bool
    ) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let clampedTitle = String(trimmedTitle.prefix(256))
        var normalizedDescription: String? = collections[index].description

        if shouldUpdateDescription {
            if let newDescription {
                let trimmedDescription = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                normalizedDescription = trimmedDescription.isEmpty ? nil : String(trimmedDescription.prefix(1024))
            } else {
                normalizedDescription = nil
            }
        }

        var collection = collections[index]
        var didChange = false

        if collection.title != clampedTitle {
            collection.title = clampedTitle
            didChange = true
        }

        if shouldUpdateDescription && collection.description != normalizedDescription {
            collection.description = normalizedDescription
            didChange = true
        }

        guard didChange else { return }

        collection.updatedAt = Date()
        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }

        if !useFallbackJSON {
            persistToDatabase(collection)
        } else {
            persistCurrentSnapshot()
        }

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func updateCollectionCover(
        collectionID: UUID,
        imageData: Data
    ) async throws {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            throw LibraryStoreError.collectionNotFound
        }

        let existingPath: String?
        switch collections[index].coverAsset.kind {
        case let .image(relativePath):
            existingPath = relativePath
        default:
            existingPath = nil
        }

        let relativePath = try await coverImageStore.saveImageData(
            imageData,
            for: collectionID,
            replacing: existingPath
        )

        var collection = collections[index]
        collection.coverAsset = CollectionCover(
            kind: .image(relativePath: relativePath),
            dominantColorHex: nil
        )
        collection.updatedAt = Date()

        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }

        if !useFallbackJSON {
            persistToDatabase(collection)
        } else {
            persistCurrentSnapshot()
        }

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func resetCollectionCover(collectionID: UUID) async {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        var collection = collections[index]
        if case let .image(relativePath) = collection.coverAsset.kind {
            try? await coverImageStore.deleteImage(at: relativePath)
        }

        let newCover = CollectionCover.generatedCover(for: collection.title)
        guard collection.coverAsset != newCover else { return }

        collection.coverAsset = newCover
        collection.updatedAt = Date()

        collections[index] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }

        if !useFallbackJSON {
            persistToDatabase(collection)
        } else {
            persistCurrentSnapshot()
        }

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

        // Persist to database
        if !useFallbackJSON {
            Task(priority: .utility) {
                do {
                    try await dbManager.updateTrack(track, in: collectionID)
                    try await dbManager.saveCollection(collection)
                } catch {
                    await MainActor.run {
                        self.lastError = error
                    }
                }
            }
        } else {
            persistCurrentSnapshot()
        }

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }

    func batchRenameTracks(
        in collectionID: UUID,
        changes: [UUID: String]
    ) {
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }

        var collection = collections[collectionIndex]
        var updatedTracks: [AudiobookTrack] = []
        var didChange = false

        for (index, track) in collection.tracks.enumerated() {
            if let newTitle = changes[track.id] {
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != track.displayName {
                    var updatedTrack = track
                    updatedTrack.displayName = String(trimmed.prefix(256))
                    collection.tracks[index] = updatedTrack
                    updatedTracks.append(updatedTrack)
                    didChange = true
                }
            }
        }

        guard didChange else { return }

        collection.updatedAt = Date()
        collections[collectionIndex] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }

        // Persist to database
        if !useFallbackJSON {
            Task(priority: .utility) {
                do {
                    // Update each track in the database
                    for track in updatedTracks {
                        try await dbManager.updateTrack(track, in: collectionID)
                    }
                    // Update collection timestamp
                    try await dbManager.saveCollection(collection)
                } catch {
                    await MainActor.run {
                        self.lastError = error
                    }
                }
            }
        } else {
            persistCurrentSnapshot()
        }

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
        case .ebook:
            return true
        case .external, .ephemeralBaidu:
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

        print("[FAVORITES] Toggling track \(track.displayName) - isFavorite=\(track.isFavorite), collection=\(collection.title)")

        collection.tracks[trackIndex] = track
        collection.updatedAt = Date()

        collections[collectionIndex] = collection
        collections.sort { $0.updatedAt > $1.updatedAt }

        // Persist to database
        if !useFallbackJSON {
            print("[FAVORITES] Using GRDB - saving favorite status...")
            Task(priority: .userInitiated) {
                do {
                    // Update track favorite status
                    try await dbManager.setFavorite(track.isFavorite, for: trackID)
                    print("[FAVORITES] ✅ Track favorite status saved")

                    // CRITICAL: Update collection's updatedAt timestamp so CloudKit sync doesn't overwrite!
                    try await dbManager.updateCollectionTimestamp(collectionID, updatedAt: collection.updatedAt)
                    print("[FAVORITES] ✅ Collection timestamp updated - will prevent CloudKit overwrite")

                    print("[FAVORITES] ✅ Database save successful for track: \(track.displayName)")
                } catch {
                    print("[FAVORITES] ❌ Database save FAILED: \(error)")
                    await MainActor.run {
                        self.lastError = error
                    }
                }
            }
        } else {
            print("[FAVORITES] Using JSON fallback...")
            persistCurrentSnapshot()
        }

        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }
    func importEbook(url: URL) async throws {
        let parser = EpubParser()
        let (title, author, chapters) = try parser.parse(epubURL: url)
        
        let collectionId = UUID()
        let now = Date()
        
        // Create tracks from chapters
        let tracks = chapters.enumerated().map { index, chapter in
            AudiobookTrack(
                id: UUID(),
                displayName: chapter.title,
                filename: chapter.filename,
                location: .text(content: chapter.content),
                fileSize: Int64(chapter.content.utf8.count),
                duration: nil,
                trackNumber: index + 1,
                checksum: nil,
                metadata: [:],
                isFavorite: false,
                favoritedAt: nil
            )
        }
        
        let collection = AudiobookCollection(
            id: collectionId,
            title: title,
            author: author,
            description: nil,
            coverAsset: .generatedCover(for: title),
            createdAt: now,
            updatedAt: now,
            source: .ebook(importedDate: now),
            tracks: tracks,
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: []
        )
        
        await MainActor.run {
            self.save(collection)
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
                try await jsonPersistence.save(snapshot)
            } catch {
                await MainActor.run {
                    self.lastError = error
                }
            }
        }
    }

    private func persistToDatabase(_ collection: AudiobookCollection) {
        let favorites = collection.tracks.filter { $0.isFavorite }
        print("[FAVORITES] persistToDatabase called for '\(collection.title)' with \(favorites.count) favorite tracks")
        Task(priority: .utility) {
            do {
                try await dbManager.saveCollection(collection)
            } catch {
                await MainActor.run {
                    self.lastError = error
                }
            }
        }
    }

    private func deleteFromDatabase(_ collectionId: UUID) {
        Task(priority: .utility) {
            do {
                try await dbManager.deleteCollection(id: collectionId)
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
    case collectionNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Library schema version \(version) is not supported."
        case .collectionNotFound:
            return "The selected collection no longer exists."
        }
    }
}

struct LibraryFile: Codable {
    var schemaVersion: Int
    var collections: [AudiobookCollection]
}

actor CollectionCoverImageStore {
    enum CoverError: LocalizedError {
        case invalidData
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidData:
                return NSLocalizedString("cover_image_invalid_data", comment: "Invalid cover image data")
            case .encodingFailed:
                return NSLocalizedString("cover_image_encoding_failed", comment: "Encoding cover image failed")
            }
        }
    }

    static let shared = CollectionCoverImageStore()
    static let directoryName = "CollectionCovers"
    nonisolated static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    nonisolated static var directoryURL: URL {
        return documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    nonisolated static let documentsDirectory: URL = {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Unable to locate documents directory")
        }
        return url
    }()

    nonisolated static func fileURL(for relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return documentsDirectory.appendingPathComponent(trimmed)
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func saveImageData(
        _ data: Data,
        for collectionID: UUID,
        replacing existingRelativePath: String?
    ) throws -> String {
        let normalizedData = try prepareImagePayload(from: data)
        try ensureDirectoryExists()

        if let existingRelativePath {
            try? deleteImage(at: existingRelativePath)
        }

        let filename = makeFilename(for: collectionID)
        let destination = Self.directoryURL.appendingPathComponent(filename)
        try normalizedData.write(to: destination, options: .atomic)
        return "\(Self.directoryName)/\(filename)"
    }

    func deleteImage(at relativePath: String) throws {
        let url = Self.fileURL(for: relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: Self.directoryURL.path) {
            try fileManager.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        }
    }

    private func makeFilename(for collectionID: UUID) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        return "\(collectionID.uuidString)-\(timestamp).jpg"
    }

    private func prepareImagePayload(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw CoverError.invalidData
        }

        let resized = image.resizedForCover(maxDimension: 900)
        guard let jpegData = resized.jpegData(compressionQuality: 0.9) else {
            throw CoverError.encodingFailed
        }
        return jpegData
    }
}

private extension UIImage {
    func resizedForCover(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return normalizedImage() }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return redraw(to: newSize)
    }

    func normalizedImage() -> UIImage {
        if imageOrientation == .up {
            return self
        }
        return redraw(to: size)
    }

    func redraw(to targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
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
            print("[FAVORITES-SYNC] Starting CloudKit sync...")
            let remoteCollections = try await syncEngine.fetchRemoteCollections()
            print("[FAVORITES-SYNC] Fetched \(remoteCollections.count) remote collections")

            let merged = await mergeLocalCollections(
                currentCollections: collections,
                remoteCollections: remoteCollections,
                syncEngine: syncEngine
            )

            if merged != collections {
                print("[FAVORITES-SYNC] ⚠️ Collections changed after merge!")
                let beforeFavorites = collections.flatMap { $0.tracks }.filter { $0.isFavorite }.count
                let afterFavorites = merged.flatMap { $0.tracks }.filter { $0.isFavorite }.count
                print("[FAVORITES-SYNC] Before merge: \(beforeFavorites) favorites")
                print("[FAVORITES-SYNC] After merge: \(afterFavorites) favorites")

                collections = merged
                persistCurrentSnapshot()
            } else {
                print("[FAVORITES-SYNC] No changes after merge")
            }
        } catch {
            print("[FAVORITES-SYNC] Sync failed: \(error)")
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
                    let localFavorites = local.tracks.filter { $0.isFavorite }.count
                    let remoteFavorites = remote.tracks.filter { $0.isFavorite }.count

                    if remote.updatedAt > local.updatedAt {
                        print("[FAVORITES-SYNC] ⚠️ Remote is newer for '\(local.title)'")
                        print("[FAVORITES-SYNC]   Local:  updatedAt=\(local.updatedAt), favorites=\(localFavorites)")
                        print("[FAVORITES-SYNC]   Remote: updatedAt=\(remote.updatedAt), favorites=\(remoteFavorites)")
                        print("[FAVORITES-SYNC]   ❌ Replacing local with remote (losing \(localFavorites) favorites!)")
                        merged[id] = remote
                    } else if local.updatedAt > remote.updatedAt {
                        print("[FAVORITES-SYNC] ✅ Local is newer for '\(local.title)', pushing to CloudKit")
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
