import Foundation
import GRDB

/// Real GRDB-based database manager for SQLite persistence
actor GRDBDatabaseManager {
    static let shared = GRDBDatabaseManager()

    var db: DatabaseQueue?
    let dbURL: URL
    let fileManager: FileManager

    init(
        dbURL: URL = DatabaseConfig.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.dbURL = dbURL
        self.fileManager = fileManager
    }

    // MARK: - Initialization

    /// Initialize the database with schema
    func initializeDatabase() throws {
        if db != nil {
            return
        }

        print("[GRDB] initializeDatabase starting...")
        try DatabaseConfig.ensureDirectoryExists()
        print("[GRDB] Directory exists")

        print("[GRDB] Creating DatabaseQueue with path: \(dbURL.path)")
        var configuration = Configuration()
        // Disable foreign key constraints at the connection level
        // We'll handle deletion order manually in deleteCollection()
        configuration.foreignKeysEnabled = false
        let db = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        self.db = db
        print("[GRDB] DatabaseQueue created successfully")

        // Create schema
        print("[GRDB] Creating schema...")
        try db.write { db in
            // Create all tables
            print("[GRDB] Executing createTableSQL...")
            try db.execute(sql: DatabaseSchema.createTableSQL)
            try addMediaKindColumnIfNeeded(in: db)
            print("[GRDB] Schema tables created")

            // Create transcription tables
            print("[GRDB] Executing transcription schema...")
            try db.execute(sql: TranscriptionDatabaseSchema.createTableSQL)
            print("[GRDB] Transcription tables created")
            try addTranscriptRepairColumnsIfNeeded(in: db)
            print("[GRDB] Transcript repair columns ensured")
            try addTranscriptionJobParagraphColumnsIfNeeded(in: db)
            print("[GRDB] Transcription job paragraph columns ensured")

            // Ensure new optional columns exist
            try addTrackCharacterCountColumnIfNeeded(in: db)
            print("[GRDB] Track character_count column ensured")

            print("[GRDB] Executing track summary schema...")
            try db.execute(sql: TrackSummaryDatabaseSchema.createTableSQL)
            try addMentionedItemsColumnIfNeeded(in: db)
            print("[GRDB] Track summary tables created")

            print("[GRDB] Executing AI generation schema...")
            try db.execute(sql: AIGenerationDatabaseSchema.createTableSQL)
            print("[GRDB] AI generation tables created")

            // Insert schema version if not exists
            print("[GRDB] Inserting schema version...")
            try db.execute(sql: """
                INSERT OR IGNORE INTO schema_state (version) VALUES (1)
            """)
            print("[GRDB] Schema version inserted")
        }
        print("[GRDB] Database initialization complete!")
    }

    // MARK: - Collection Operations

    /// Save a collection to the database
    func saveCollection(_ collection: AudiobookCollection) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[GRDB] Starting save for collection: \(collection.title)")

        // Check if this is a lightweight collection (loaded without tracks)
        // If so, we MUST NOT delete existing tracks/tags/states.
        // We only update the collection metadata.
        let isLightweight = collection.tracks.isEmpty && collection.trackCount > 0
        
        if isLightweight {
            print("[GRDB] Detected lightweight collection save. Updating metadata only.")
            try db.write { db in
                try db.execute(sql:
                    """
                    UPDATE collections SET
                        title = ?, author = ?, description = ?,
                        cover_kind = ?, cover_data = ?, cover_dominant_color = ?,
                        updated_at = ?,
                        source_type = ?, source_payload = ?,
                        last_played_track_id = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        collection.title,
                        collection.author,
                        collection.description,
                        collection.coverAsset.kind.typeString,
                        collection.coverAsset.kind.dataJSON(),
                        collection.coverAsset.dominantColorHex,
                        collection.updatedAt,
                        collection.source.typeString,
                        collection.source.payloadJSON(),
                        collection.lastPlayedTrackId?.uuidString,
                        collection.id.uuidString
                    ]
                )
            }
            return
        }

        try db.write { db in
            // Delete existing data in CORRECT DEPENDENCY ORDER
            // (reverse of creation order to respect foreign keys)
            print("[GRDB] Deleting playback states for collection: \(collection.id.uuidString)")
            try db.execute(sql: "DELETE FROM playback_states WHERE collection_id = ?", arguments: [collection.id.uuidString])

            print("[GRDB] Deleting tracks for collection: \(collection.id.uuidString)")
            try db.execute(sql: "DELETE FROM tracks WHERE collection_id = ?", arguments: [collection.id.uuidString])

            print("[GRDB] Deleting tags for collection: \(collection.id.uuidString)")
            try db.execute(sql: "DELETE FROM tags WHERE collection_id = ?", arguments: [collection.id.uuidString])

            print("[GRDB] Deleting collection: \(collection.id.uuidString)")
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [collection.id.uuidString])

            // Insert collection
            print("[GRDB] Inserting collection: \(collection.title)")
            try db.execute(sql:
                """
                INSERT INTO collections (
                    id, title, author, description,
                    cover_kind, cover_data, cover_dominant_color,
                    created_at, updated_at,
                    source_type, source_payload,
                    last_played_track_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    collection.id.uuidString,
                    collection.title,
                    collection.author,
                    collection.description,
                    collection.coverAsset.kind.typeString,
                    collection.coverAsset.kind.dataJSON(),
                    collection.coverAsset.dominantColorHex,
                    collection.createdAt,
                    collection.updatedAt,
                    collection.source.typeString,
                    collection.source.payloadJSON(),
                    collection.lastPlayedTrackId?.uuidString
                ]
            )

            // Insert tracks
            print("[GRDB] Inserting \(collection.tracks.count) tracks")
            for (idx, track) in collection.tracks.enumerated() {
                let isFavStr = track.isFavorite ? "✓" : "✗"
                if track.isFavorite {
                    print("[FAVORITES-DB] Saving favorite track: \(track.displayName)")
                }
                try db.execute(sql:
                    """
                    INSERT INTO tracks (
                        id, collection_id,
                        display_name, filename,
                        location_type, location_payload,
                        file_size, duration, track_number,
                        checksum, metadata_json,
                        media_kind,
                        is_favorite, favorited_at,
                        character_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        track.id.uuidString,
                        collection.id.uuidString,
                        track.displayName,
                        track.filename,
                        track.location.typeString,
                        track.location.payloadJSON(),
                        track.fileSize,
                        track.duration,
                        track.trackNumber,
                        track.checksum,
                        track.metadata.isEmpty ? nil : encodeJSON(track.metadata),
                        track.mediaKind.rawValue,
                        track.isFavorite ? 1 : 0,
                        track.favoritedAt,
                        track.characterCount
                    ]
                )
                if idx % 20 == 0 {
                    print("[GRDB] Inserted \(idx) tracks...")
                }
            }

            // Insert playback states
            print("[GRDB] Inserting playback states")
            for (trackId, state) in collection.playbackStates {
                try db.execute(sql:
                    """
                    INSERT INTO playback_states (
                        track_id, collection_id,
                        position, duration, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        trackId.uuidString,
                        collection.id.uuidString,
                        state.position,
                        state.duration,
                        state.updatedAt
                    ]
                )
            }

            // Insert tags
            print("[GRDB] Inserting \(collection.tags.count) tags")
            for tag in collection.tags {
                try db.execute(
                    sql: "INSERT INTO tags (collection_id, tag) VALUES (?, ?)",
                    arguments: [collection.id.uuidString, tag]
                )
            }
        }

        print("[GRDB] Successfully saved collection: \(collection.title)")
    }

    /// Load a collection by ID
    func loadCollection(id: UUID) throws -> AudiobookCollection? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            // Load collection
            let collectionRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM collections WHERE id = ?",
                arguments: [id.uuidString]
            )

            guard let collectionRow = collectionRow else { return nil }

            // Load tracks
            let trackRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM tracks WHERE collection_id = ? ORDER BY track_number",
                arguments: [id.uuidString]
            )

            // Load playback states
            let playbackRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM playback_states WHERE collection_id = ?",
                arguments: [id.uuidString]
            )

            // Load tags
            let tagRows = try Row.fetchAll(
                db,
                sql: "SELECT tag FROM tags WHERE collection_id = ?",
                arguments: [id.uuidString]
            )

            // Reconstruct the collection
            return try reconstructCollection(
                collectionRow: collectionRow,
                trackRows: trackRows,
                playbackRows: playbackRows,
                tagRows: tagRows,
                trackCount: trackRows.count
            )
        }
    }

    /// Load all collections (Lightweight: No tracks, playback states, or tags)
    func loadAllCollections() throws -> [AudiobookCollection] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[GRDB] Starting loadAllCollections (Lightweight)")

        return try db.read { db in
            // Fetch collections with track count
            let sql = """
            SELECT c.*, (SELECT COUNT(*) FROM tracks t WHERE t.collection_id = c.id) as track_count
            FROM collections c
            """
            let collectionRows = try Row.fetchAll(db, sql: sql)
            print("[GRDB] Found \(collectionRows.count) collection rows")

            var collections: [AudiobookCollection] = []

            for collectionRow in collectionRows {
                // Pass empty arrays for lazy loading
                if let collection = try reconstructCollection(
                    collectionRow: collectionRow,
                    trackRows: [],
                    playbackRows: [],
                    tagRows: [],
                    trackCount: collectionRow["track_count"]
                ) {
                    collections.append(collection)
                }
            }

            print("[GRDB] Returning \(collections.count) lightweight collections")
            return collections
        }
    }

    /// Load details for a specific collection (Tracks, Playback States, Tags)
    func loadCollectionDetails(id: UUID) throws -> (tracks: [AudiobookTrack], playbackStates: [UUID: TrackPlaybackState], tags: [String]) {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try db.read { db in
            // Load tracks
            let trackRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM tracks WHERE collection_id = ? ORDER BY track_number",
                arguments: [id.uuidString]
            )
            
            var tracks: [AudiobookTrack] = []
            for trackRow in trackRows {
                if let track = try reconstructTrack(row: trackRow) {
                    tracks.append(track)
                }
            }
            
            // Load playback states
            let playbackRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM playback_states WHERE collection_id = ?",
                arguments: [id.uuidString]
            )
            
            var playbackStates: [UUID: TrackPlaybackState] = [:]
            for pbRow in playbackRows {
                if let trackIdStr = pbRow["track_id"] as? String,
                   let trackId = UUID(uuidString: trackIdStr),
                   let state = try reconstructPlaybackState(row: pbRow) {
                    playbackStates[trackId] = state
                }
            }
            
            // Load tags
            let tagRows = try Row.fetchAll(
                db,
                sql: "SELECT tag FROM tags WHERE collection_id = ?",
                arguments: [id.uuidString]
            )
            let tags = tagRows.compactMap { $0["tag"] as? String }
            
            return (tracks, playbackStates, tags)
        }
    }

    /// Delete a collection
    func deleteCollection(id: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            // Delete in reverse dependency order
            try db.execute(sql: "DELETE FROM playback_states WHERE collection_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM tracks WHERE collection_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM tags WHERE collection_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Track Operations

    /// Update a track
    func updateTrack(_ track: AudiobookTrack, in collectionId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: 
                """
                UPDATE tracks SET
                    display_name = ?,
                    filename = ?,
                    location_type = ?,
                    location_payload = ?,
                    file_size = ?,
                    duration = ?,
                    track_number = ?,
                    checksum = ?,
                    metadata_json = ?,
                    media_kind = ?,
                    is_favorite = ?,
                    favorited_at = ?,
                    character_count = ?
                WHERE id = ? AND collection_id = ?
                """,
                arguments: [
                    track.displayName,
                    track.filename,
                    track.location.typeString,
                    track.location.payloadJSON(),
                    track.fileSize,
                    track.duration,
                    track.trackNumber,
                    track.checksum,
                    track.metadata.isEmpty ? nil : encodeJSON(track.metadata),
                    track.mediaKind.rawValue,
                    track.isFavorite ? 1 : 0,
                    track.favoritedAt,
                    track.characterCount,
                    track.id.uuidString,
                    collectionId.uuidString
                ]
            )
        }
    }

    /// Batch update multiple tracks
    func updateTracks(_ tracks: [AudiobookTrack], in collectionId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            for track in tracks {
                try db.execute(sql:
                    """
                    UPDATE tracks SET
                        display_name = ?,
                        filename = ?,
                        location_type = ?,
                        location_payload = ?,
                        file_size = ?,
                        duration = ?,
                        track_number = ?,
                        checksum = ?,
                        metadata_json = ?,
                        media_kind = ?,
                        is_favorite = ?,
                        favorited_at = ?,
                        character_count = ?
                    WHERE id = ? AND collection_id = ?
                    """,
                    arguments: [
                        track.displayName,
                        track.filename,
                        track.location.typeString,
                        track.location.payloadJSON(),
                        track.fileSize,
                        track.duration,
                        track.trackNumber,
                        track.checksum,
                        track.metadata.isEmpty ? nil : encodeJSON(track.metadata),
                        track.mediaKind.rawValue,
                        track.isFavorite ? 1 : 0,
                        track.favoritedAt,
                        track.characterCount,
                        track.id.uuidString,
                        collectionId.uuidString
                    ]
                )
            }
        }
    }

    /// Remove a track from a collection
    func removeTrack(id: UUID, from collectionId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(
                sql: "DELETE FROM playback_states WHERE track_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM tracks WHERE id = ? AND collection_id = ?",
                arguments: [id.uuidString, collectionId.uuidString]
            )
        }
    }

    // MARK: - Playback State Operations

    /// Save playback state for a track
    func savePlaybackState(
        trackId: UUID,
        collectionId: UUID,
        position: TimeInterval,
        duration: TimeInterval?
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            // Update playback state
            try db.execute(sql:
                """
                INSERT OR REPLACE INTO playback_states (
                    track_id, collection_id, position, duration, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    trackId.uuidString,
                    collectionId.uuidString,
                    position,
                    duration,
                    Date()
                ]
            )

            // Also update the last_played_track_id in the collection
            try db.execute(sql:
                """
                UPDATE collections
                SET last_played_track_id = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    trackId.uuidString,
                    Date(),
                    collectionId.uuidString
                ]
            )
        }
    }

    /// Load playback state for a track
    func loadPlaybackState(trackId: UUID) throws -> TrackPlaybackState? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM playback_states WHERE track_id = ?",
                arguments: [trackId.uuidString]
            ) else {
                return nil
            }

            return try reconstructPlaybackState(row: row)
        }
    }

    /// Load all playback states for a collection
    func loadPlaybackStates(for collectionId: UUID) throws -> [UUID: TrackPlaybackState] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM playback_states WHERE collection_id = ?",
                arguments: [collectionId.uuidString]
            )

            var states: [UUID: TrackPlaybackState] = [:]

            for row in rows {
                guard let trackIdStr = row["track_id"] as? String,
                      let trackId = UUID(uuidString: trackIdStr) else {
                    continue
                }

                if let state = try reconstructPlaybackState(row: row) {
                    states[trackId] = state
                }
            }

            return states
        }
    }

    /// Load a single track (and its owning collection) by track UUID
    /// Returns nil if the track does not exist.
    func loadTrack(id: UUID) throws -> (track: AudiobookTrack, collectionId: UUID)? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM tracks WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }

            guard let collectionIdStr = row["collection_id"] as? String,
                  let collectionId = UUID(uuidString: collectionIdStr),
                  let track = try reconstructTrack(row: row) else {
                return nil
            }

            return (track, collectionId)
        }
    }

    // MARK: - Favorite Operations

    /// Toggle favorite status for a track
    func setFavorite(_ isFavorite: Bool, for trackId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[FAVORITES-DB] setFavorite called: trackId=\(trackId.uuidString), isFavorite=\(isFavorite)")

        try db.write { db in
            let intValue = isFavorite ? 1 : 0
            print("[FAVORITES-DB] About to UPDATE with is_favorite=\(intValue)")

            try db.execute(sql:
                """
                UPDATE tracks SET
                    is_favorite = ?,
                    favorited_at = ?
                WHERE id = ?
                """,
                arguments: [
                    intValue,
                    isFavorite ? Date() : nil,
                    trackId.uuidString
                ]
            )

            // Check how many rows were affected
            let changes = db.changesCount
            print("[FAVORITES-DB] UPDATE executed, affected \(changes) row(s)")

            // Verify the update worked
            if let row = try Row.fetchOne(db, sql: "SELECT is_favorite FROM tracks WHERE id = ?", arguments: [trackId.uuidString]) {
                // Use typed subscript to properly extract the Int value
                let intValue: Int? = row["is_favorite"]
                let savedFavorite = (intValue ?? 0) == 1
                print("[FAVORITES-DB] ✓ Verification: track \(trackId.uuidString) has is_favorite=\(intValue as Any), bool=\(savedFavorite)")
            } else {
                print("[FAVORITES-DB] ❌ ERROR: Track \(trackId.uuidString) not found in database!")
            }
        }
    }

    /// Load all favorite tracks
    func loadFavoriteTracks() throws -> [AudiobookTrack] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM tracks WHERE is_favorite = 1 ORDER BY favorited_at DESC"
            )

            var tracks: [AudiobookTrack] = []
            for row in rows {
                if let track = try reconstructTrack(row: row) {
                    tracks.append(track)
                }
            }
            return tracks
        }
    }

    /// Update collection's updatedAt timestamp (used when favorites change)
    func updateCollectionTimestamp(_ collectionId: UUID, updatedAt: Date) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[FAVORITES-DB] Updating collection timestamp: \(collectionId.uuidString) to \(updatedAt)")

        try db.write { db in
            try db.execute(sql:
                """
                UPDATE collections SET
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [updatedAt, collectionId.uuidString]
            )

            let changes = db.changesCount
            print("[FAVORITES-DB] Collection timestamp update affected \(changes) row(s)")
        }
    }

    // MARK: - Tag Operations

    /// Add tags to a collection
    func addTags(_ tags: [String], to collectionId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            for tag in tags {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO tags (collection_id, tag) VALUES (?, ?)",
                    arguments: [collectionId.uuidString, tag]
                )
            }
        }
    }

    /// Load tags for a collection
    func loadTags(for collectionId: UUID) throws -> [String] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT tag FROM tags WHERE collection_id = ? ORDER BY tag",
                arguments: [collectionId.uuidString]
            )

            return rows.compactMap { $0["tag"] as? String }
        }
    }

    /// Remove a tag from a collection
    func removeTag(_ tag: String, from collectionId: UUID) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(
                sql: "DELETE FROM tags WHERE collection_id = ? AND tag = ?",
                arguments: [collectionId.uuidString, tag]
            )
        }
    }

    // MARK: - Helper Methods

    /// SQLite DATETIME formatter: "YYYY-MM-DD HH:MM:SS.mmm"
    static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func reconstructCollection(
        collectionRow: Row,
        trackRows: [Row],
        playbackRows: [Row],
        tagRows: [Row],
        trackCount: Int? = nil
    ) throws -> AudiobookCollection? {
        guard let id = collectionRow["id"] as? String,
              let uuid = UUID(uuidString: id),
              let title = collectionRow["title"] as? String,
              let coverKindStr = collectionRow["cover_kind"] as? String,
              let sourceTypeStr = collectionRow["source_type"] as? String,
              let sourcePayload = collectionRow["source_payload"] as? String else {
            return nil
        }

        // Parse DATETIME fields - GRDB returns them as String
        let createdAtValue = collectionRow["created_at"]
        let createdAt: Date
        if let date = createdAtValue as? Date {
            createdAt = date
        } else if let dateString = createdAtValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            createdAt = parsedDate
        } else {
            return nil
        }

        let updatedAtValue = collectionRow["updated_at"]
        let updatedAt: Date
        if let date = updatedAtValue as? Date {
            updatedAt = date
        } else if let dateString = updatedAtValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            updatedAt = parsedDate
        } else {
            return nil
        }

        // Reconstruct cover
        let coverData = collectionRow["cover_data"] as? String
        let coverDominant = collectionRow["cover_dominant_color"] as? String
        let coverKind = try decodeCoverKind(type: coverKindStr, data: coverData)

        let cover = CollectionCover(kind: coverKind, dominantColorHex: coverDominant)

        // Reconstruct source
        let source = try decodeSource(type: sourceTypeStr, payload: sourcePayload)

        // Reconstruct tracks
        var tracks: [AudiobookTrack] = []
        for trackRow in trackRows {
            if let track = try reconstructTrack(row: trackRow) {
                tracks.append(track)
            }
        }

        // Reconstruct playback states
        var playbackStates: [UUID: TrackPlaybackState] = [:]
        for pbRow in playbackRows {
            guard let trackIdStr = pbRow["track_id"] as? String,
                  let trackId = UUID(uuidString: trackIdStr) else {
                continue
            }
            if let state = try reconstructPlaybackState(row: pbRow) {
                playbackStates[trackId] = state
            }
        }

        // Reconstruct tags
        let tags = tagRows.compactMap { $0["tag"] as? String }

        // Get optional fields
        let author = collectionRow["author"] as? String
        let description = collectionRow["description"] as? String
        let lastPlayedTrackIdStr = collectionRow["last_played_track_id"] as? String
        let lastPlayedTrackId = lastPlayedTrackIdStr.flatMap(UUID.init)

        return AudiobookCollection(
            id: uuid,
            title: title,
            author: author,
            description: description,
            coverAsset: cover,
            createdAt: createdAt,
            updatedAt: updatedAt,
            source: source,
            tracks: tracks,
            lastPlayedTrackId: lastPlayedTrackId,
            playbackStates: playbackStates,
            tags: tags,
            trackCount: trackCount
        )
    }

    private func reconstructTrack(row: Row) throws -> AudiobookTrack? {
        guard let id = row["id"] as? String,
              let uuid = UUID(uuidString: id),
              let displayName = row["display_name"] as? String,
              let filename = row["filename"] as? String,
              let locationTypeStr = row["location_type"] as? String,
              let locationPayload = row["location_payload"] as? String,
              let fileSize: Int64 = row["file_size"],
              let trackNumber: Int = row["track_number"] else {
            return nil
        }

        let location = try decodeLocation(type: locationTypeStr, payload: locationPayload)

        let duration = row["duration"] as? TimeInterval
        let checksum = row["checksum"] as? String
        let metadataJson = row["metadata_json"] as? String
        let metadata = metadataJson.flatMap { decodeJSON($0) as? [String: String] } ?? [:]
        let mediaKindRaw = row["media_kind"] as? String ?? "audio"
        let storedMediaKind = AudiobookTrack.MediaKind(rawValue: mediaKindRaw) ?? .audio
        let mediaKind = resolveMediaKind(storedMediaKind, filename: filename)
        let isFavoriteValue: Int? = row["is_favorite"]
        let isFavorite = (isFavoriteValue ?? 0) == 1

        // Handle favoritedAt - GRDB returns DATETIME as String, not Date
        let favoritedAtValue = row["favorited_at"]
        let favoritedAt: Date?
        if let date = favoritedAtValue as? Date {
            favoritedAt = date
        } else if let dateString = favoritedAtValue as? String {
            favoritedAt = Self.sqliteDateFormatter.date(from: dateString)
        } else {
            favoritedAt = nil
        }

        if isFavorite {
            print("[FAVORITES-DB] Read favorite track from DB: \(displayName), favoritedAt=\(favoritedAt as Any)")
        }

        let charCount: Int? = row["character_count"]

        return AudiobookTrack(
            id: uuid,
            displayName: displayName,
            filename: filename,
            location: location,
            fileSize: fileSize,
            duration: duration,
            trackNumber: trackNumber,
            checksum: checksum,
            metadata: metadata,
            mediaKind: mediaKind,
            isFavorite: isFavorite,
            favoritedAt: favoritedAt,
            characterCount: charCount
        )
    }

    private func resolveMediaKind(_ stored: AudiobookTrack.MediaKind, filename: String) -> AudiobookTrack.MediaKind {
        if stored == .audio {
            let detected = PlayableMediaFormat.mediaKind(forFilename: filename)
            if detected == .video {
                return .video
            }
        }
        return stored
    }

    private func reconstructPlaybackState(row: Row) throws -> TrackPlaybackState? {
        guard let position = row["position"] as? TimeInterval else {
            return nil
        }

        // Handle updatedAt - GRDB returns DATETIME as String, not Date
        let updatedAtValue = row["updated_at"]
        let updatedAt: Date
        if let date = updatedAtValue as? Date {
            updatedAt = date
        } else if let dateString = updatedAtValue as? String {
            guard let parsedDate = Self.sqliteDateFormatter.date(from: dateString) else {
                return nil
            }
            updatedAt = parsedDate
        } else {
            return nil
        }

        let duration = row["duration"] as? TimeInterval

        return TrackPlaybackState(
            position: position,
            duration: duration,
            updatedAt: updatedAt
        )
    }

    // MARK: - Encoding/Decoding Helpers

    private func decodeCoverKind(type: String, data: String?) throws -> CollectionCover.Kind {
        switch type {
        case "solid":
            guard let data = data,
                  let dict = decodeJSON(data) as? [String: Any],
                  let colorHex = dict["colorHex"] as? String else {
                throw DatabaseError.inconsistentData("Invalid solid cover data")
            }
            return .solid(colorHex: colorHex)

        case "image":
            guard let data = data,
                  let dict = decodeJSON(data) as? [String: Any],
                  let path = dict["relativePath"] as? String else {
                throw DatabaseError.inconsistentData("Invalid image cover data")
            }
            return .image(relativePath: path)

        case "remote":
            guard let data = data,
                  let dict = decodeJSON(data) as? [String: Any],
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr) else {
                throw DatabaseError.inconsistentData("Invalid remote cover data")
            }
            return .remote(url: url)

        default:
            throw DatabaseError.inconsistentData("Unknown cover kind: \(type)")
        }
    }

    private func decodeSource(type: String, payload: String) throws -> AudiobookCollection.Source {
        guard let dict = decodeJSON(payload) as? [String: Any] else {
            throw DatabaseError.inconsistentData("Invalid source payload JSON")
        }

        switch type {
        case "baiduNetdisk":
            guard let folderPath = dict["folderPath"] as? String,
                  let tokenScope = dict["tokenScope"] as? String else {
                throw DatabaseError.inconsistentData("Missing Baidu source fields")
            }
            return .baiduNetdisk(folderPath: folderPath, tokenScope: tokenScope)

        case "local":
            guard let bookmarkStr = dict["directoryBookmark"] as? String,
                  let bookmarkData = Data(base64Encoded: bookmarkStr) else {
                throw DatabaseError.inconsistentData("Invalid local bookmark data")
            }
            return .local(directoryBookmark: bookmarkData)

        case "external":
            guard let description = dict["description"] as? String else {
                throw DatabaseError.inconsistentData("Missing external description")
            }
            return .external(description: description)

        case "ebook":
            guard let dateStr = dict["importedDate"] as? String else {
                // Try decoding as timestamp if string fails (though Codable usually encodes Date as float)
                if let timestamp = dict["importedDate"] as? Double {
                    return .ebook(importedDate: Date(timeIntervalSinceReferenceDate: timestamp))
                }
                throw DatabaseError.inconsistentData("Missing ebook importedDate")
            }
            // Codable default date encoding might be ISO8601 or reference date.
            // Let's try to parse it if it's a string, or assume it's a timestamp if double.
            // Actually, Codable for Date defaults to reference date (Double) unless configured otherwise.
            // But here we are decoding JSON manually.
            // Let's see how it was encoded.
            // LibraryModels.swift uses default Codable.
            // Default JSONEncoder encodes Date as float (timeIntervalSinceReferenceDate).
            // So dict["importedDate"] should be a Double.
            if let timestamp = dict["importedDate"] as? Double {
                return .ebook(importedDate: Date(timeIntervalSinceReferenceDate: timestamp))
            }
            // Fallback for ISO8601 if that was used
            if let date = Self.sqliteDateFormatter.date(from: dateStr) {
                 return .ebook(importedDate: date)
            }
             throw DatabaseError.inconsistentData("Invalid ebook importedDate")

        default:
            throw DatabaseError.inconsistentData("Unknown source type: \(type)")
        }
    }

    private func decodeLocation(type: String, payload: String) throws -> AudiobookTrack.Location {
        guard let dict = decodeJSON(payload) as? [String: Any] else {
            throw DatabaseError.inconsistentData("Invalid location payload JSON")
        }

        switch type {
        case "baidu":
            guard let fsId = dict["fsId"] as? Int64,
                  let path = dict["path"] as? String else {
                throw DatabaseError.inconsistentData("Missing Baidu location fields")
            }
            return .baidu(fsId: fsId, path: path)

        case "local":
            guard let bookmarkStr = dict["urlBookmark"] as? String,
                  let bookmarkData = Data(base64Encoded: bookmarkStr) else {
                throw DatabaseError.inconsistentData("Invalid local bookmark")
            }
            return .local(urlBookmark: bookmarkData)

        case "external":
            guard let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr) else {
                throw DatabaseError.inconsistentData("Invalid external URL")
            }
            return .external(url: url)

        case "text":
            guard let content = dict["content"] as? String else {
                throw DatabaseError.inconsistentData("Missing text content")
            }
            return .text(content: content)

        case "cachedText":
            guard let filename = dict["filename"] as? String else {
                throw DatabaseError.inconsistentData("Missing cached text filename")
            }
            return .cachedText(filename: filename)

        default:
            throw DatabaseError.inconsistentData("Unknown location type: \(type)")
        }
    }

    // MARK: - Backup Helpers

    struct TranscriptionStats {
        let transcripts: Int
        let segments: Int
        let jobs: Int
    }

    func exportDatabaseSnapshot(to destinationURL: URL) throws {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        try db.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: dbURL, to: destinationURL)
    }

    func replaceDatabase(with snapshotURL: URL) throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw DatabaseError.loadFailed("Snapshot not found at \(snapshotURL.path)")
        }

        if let existingDB = db {
            existingDB.releaseMemory()
        }
        db = nil

        try DatabaseConfig.ensureDirectoryExists()

        let backupURL = dbURL.deletingLastPathComponent()
            .appendingPathComponent("library.sqlite.backup-\(UUID().uuidString)")
        var hasBackup = false

        if fileManager.fileExists(atPath: dbURL.path) {
            try fileManager.copyItem(at: dbURL, to: backupURL)
            hasBackup = true
        }

        do {
            if fileManager.fileExists(atPath: dbURL.path) {
                try fileManager.removeItem(at: dbURL)
            }

            try fileManager.copyItem(at: snapshotURL, to: dbURL)

            if hasBackup {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            if hasBackup {
                try? fileManager.removeItem(at: dbURL)
                try? fileManager.moveItem(at: backupURL, to: dbURL)
            }
            throw error
        }
    }

    func fetchTranscriptionStats() throws -> TranscriptionStats {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let transcriptCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcripts") ?? 0
            let segmentCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcript_segments") ?? 0
            let jobCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcription_jobs") ?? 0
            return TranscriptionStats(transcripts: transcriptCount, segments: segmentCount, jobs: jobCount)
        }
    }

    // MARK: - JSON Utilities

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON(_ jsonString: String) -> Any? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Transcription Operations

    /// Save a transcript to the database
    func saveTranscript(
        id: String,
        trackId: String,
        collectionId: String,
        language: String,
        fullText: String,
        jobStatus: String,
        jobId: String?
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO transcripts (
                    id, track_id, collection_id, language,
                    full_text, created_at, updated_at,
                    job_status, job_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    trackId,
                    collectionId,
                    language,
                    fullText,
                    Date(),
                    Date(),
                    jobStatus,
                    jobId
                ]
            )
        }
    }

    /// Load transcript by track ID
    func loadTranscript(forTrackId trackId: String) throws -> Transcript? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[GRDB] Loading transcript for track: \(trackId)")

        let transcript: Transcript? = try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transcripts WHERE track_id = ?",
                arguments: [trackId]
            ) else {
                print("[GRDB] No transcript found for track: \(trackId)")
                return nil as Transcript?
            }

            print("[GRDB] Found transcript row, reconstructing...")
            return try reconstructTranscript(row: row)
        }

        if let t = transcript {
            print("[GRDB] Successfully loaded transcript: \(t.id), status: \(t.jobStatus), text length: \(t.fullText.count)")
        }

        return transcript
    }

    /// Check if a track has a completed transcript
    func hasCompletedTranscript(forTrackId trackId: String) throws -> Bool {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let hasTranscript = try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT job_status FROM transcripts WHERE track_id = ? LIMIT 1",
                arguments: [trackId]
            ) else {
                return false
            }

            let jobStatus: String = row["job_status"]
            let normalized = jobStatus.lowercased()
            return normalized == "complete" || normalized == "completed"
        }

        return hasTranscript
    }

    /// Load all transcript segments for a transcript
    func loadTranscriptSegments(forTranscriptId transcriptId: String) throws -> [TranscriptSegment] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let segments = try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE transcript_id = ? ORDER BY start_time_ms",
                arguments: [transcriptId]
            )

            print("[GRDB] Found \(rows.count) segment rows")
            return try rows.compactMap { try reconstructTranscriptSegment(row: $0) }
        }

        print("[GRDB] Successfully loaded \(segments.count) segments")
        return segments
    }

    /// Count transcript segments for a transcript without loading them all
    func countTranscriptSegments(forTranscriptId transcriptId: String) throws -> Int {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let count = try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE transcript_id = ?",
                arguments: [transcriptId]
            ) ?? 0
        }

        return count
    }

    /// Delete transcript and associated segments for a track
    func deleteTranscript(forTrackId trackId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            if let transcriptRow = try Row.fetchOne(
                db,
                sql: "SELECT id FROM transcripts WHERE track_id = ?",
                arguments: [trackId]
            ), let transcriptId = transcriptRow["id"] as? String {
                try db.execute(
                    sql: "DELETE FROM transcript_segments WHERE transcript_id = ?",
                    arguments: [transcriptId]
                )
                try db.execute(
                    sql: "DELETE FROM transcripts WHERE id = ?",
                    arguments: [transcriptId]
                )
            }
        }
    }

    /// Save transcript segments
    func saveTranscriptSegments(_ segments: [TranscriptSegment], for transcriptId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            // Delete existing segments
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE transcript_id = ?",
                arguments: [transcriptId]
            )

            // Insert new segments
            for segment in segments {
                try db.execute(sql: """
                    INSERT INTO transcript_segments (
                        id, transcript_id, text,
                        start_time_ms, end_time_ms,
                        confidence, speaker, language,
                        last_repair_model, last_repair_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id,
                        transcriptId,
                        segment.text,
                        segment.startTimeMs,
                        segment.endTimeMs,
                        segment.confidence,
                        segment.speaker,
                        segment.language,
                        segment.lastRepairModel,
                        segment.lastRepairAt
                    ]
                )
            }
        }
    }

    /// Apply in-place transcript repairs and recompute full_text
    func applyTranscriptRepairs(
        transcriptId: String,
        editedTextsBySegmentId: [String: String],
        model: String,
        repairedAt: Date = Date()
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            for (segmentId, newText) in editedTextsBySegmentId {
                try db.execute(
                    sql: """
                        UPDATE transcript_segments
                        SET text = ?, last_repair_model = ?, last_repair_at = ?
                        WHERE id = ? AND transcript_id = ?
                        """,
                    arguments: [newText, model, repairedAt, segmentId, transcriptId]
                )
            }

            let orderedTexts: [String] = try String.fetchAll(
                db,
                sql: "SELECT text FROM transcript_segments WHERE transcript_id = ? ORDER BY start_time_ms",
                arguments: [transcriptId]
            )
            let fullText = orderedTexts.joined(separator: " ")

            try db.execute(
                sql: """
                    UPDATE transcripts
                    SET full_text = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [fullText, repairedAt, transcriptId]
            )
        }
    }
    
    /// Update transcript job metadata (job id/status)
    func updateTranscriptJobMetadata(
        trackId: String,
        jobId: String,
        status: String
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(
                sql: """
                UPDATE transcripts
                SET job_id = ?, job_status = ?, error_message = NULL, updated_at = ?
                WHERE track_id = ?
                """,
                arguments: [
                    jobId,
                    status,
                    Date(),
                    trackId
                ]
            )
        }
    }

    /// Update transcript contents and mark completion
    func finalizeTranscript(
        trackId: String,
        fullText: String,
        jobStatus: String = "complete",
        errorMessage: String? = nil
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(
                sql: """
                UPDATE transcripts
                SET full_text = ?, job_status = ?, error_message = ?, updated_at = ?
                WHERE track_id = ?
                """,
                arguments: [
                    fullText,
                    jobStatus,
                    errorMessage,
                    Date(),
                    trackId
                ]
            )
        }
    }

    /// Mark a transcript as failed with an error message
    func markTranscriptFailed(trackId: String, message: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(
                sql: """
                UPDATE transcripts
                SET job_status = 'failed', error_message = ?, updated_at = ?
                WHERE track_id = ?
                """,
                arguments: [
                    message,
                    Date(),
                    trackId
                ]
            )
        }
    }

    /// Update transcript job status
    func updateTranscriptionJobStatus(
        jobId: String,
        status: String,
        progress: Double? = nil
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                UPDATE transcription_jobs
                SET status = ?, progress = ?, last_attempt_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status,
                    progress,
                    Date(),
                    jobId
                ]
            )
        }
    }

    /// Save a complete transcript with segments
    func saveTranscript(_ transcript: Transcript, segments: [TranscriptSegment]) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            // Find existing transcript ID to cleanup segments
            let oldTranscriptId = try String.fetchOne(db, sql: "SELECT id FROM transcripts WHERE track_id = ?", arguments: [transcript.trackId])
            
            if let oldId = oldTranscriptId {
                try db.execute(sql: "DELETE FROM transcript_segments WHERE transcript_id = ?", arguments: [oldId])
                try db.execute(sql: "DELETE FROM transcripts WHERE id = ?", arguments: [oldId])
            }
            
            // Insert transcript
            try db.execute(sql: """
                INSERT INTO transcripts (
                    id, track_id, collection_id, language, full_text,
                    created_at, updated_at, job_status, job_id, error_message
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    transcript.id,
                    transcript.trackId,
                    transcript.collectionId,
                    transcript.language,
                    transcript.fullText,
                    transcript.createdAt,
                    transcript.updatedAt,
                    transcript.jobStatus,
                    transcript.jobId,
                    transcript.errorMessage
                ]
            )

            // Insert segments
            for segment in segments {
                try db.execute(sql: """
                    INSERT INTO transcript_segments (
                        id, transcript_id, text, start_time_ms, end_time_ms,
                        confidence, speaker, language, last_repair_model, last_repair_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id,
                        segment.transcriptId,
                        segment.text,
                        segment.startTimeMs,
                        segment.endTimeMs,
                        segment.confidence,
                        segment.speaker,
                        segment.language,
                        segment.lastRepairModel,
                        segment.lastRepairAt
                    ]
                )
            }
        }
    }

    // MARK: - Private Helpers for Transcription

    private func reconstructTranscript(row: Row) throws -> Transcript? {
        guard let id = row["id"] as? String,
              let trackId = row["track_id"] as? String,
              let collectionId = row["collection_id"] as? String,
              let fullText = row["full_text"] as? String,
              let jobStatus = row["job_status"] as? String else {
            return nil
        }

        let language = row["language"] as? String ?? "en"
        let jobId = row["job_id"] as? String
        let errorMessage = row["error_message"] as? String

        // Parse dates
        let createdAtValue = row["created_at"]
        let createdAt: Date
        if let date = createdAtValue as? Date {
            createdAt = date
        } else if let dateString = createdAtValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            createdAt = parsedDate
        } else {
            return nil
        }

        let updatedAtValue = row["updated_at"]
        let updatedAt: Date
        if let date = updatedAtValue as? Date {
            updatedAt = date
        } else if let dateString = updatedAtValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            updatedAt = parsedDate
        } else {
            return nil
        }

        return Transcript(
            id: id,
            trackId: trackId,
            collectionId: collectionId,
            language: language,
            fullText: fullText,
            createdAt: createdAt,
            updatedAt: updatedAt,
            jobStatus: jobStatus,
            jobId: jobId,
            errorMessage: errorMessage
        )
    }

    private func reconstructTranscriptSegment(row: Row) throws -> TranscriptSegment? {
        guard let id = row["id"] as? String,
              let transcriptId = row["transcript_id"] as? String,
              let text = row["text"] as? String else {
            return nil
        }

        // Use type-annotated subscripts for integers (GRDB compatibility)
        let startTimeMs: Int = row["start_time_ms"]
        let endTimeMs: Int = row["end_time_ms"]

        let confidence = row["confidence"] as? Double
        let speaker = row["speaker"] as? String
        let language = row["language"] as? String
        let lastRepairModel = row["last_repair_model"] as? String

        let lastRepairAtValue = row["last_repair_at"]
        let lastRepairDate: Date?
        if let date = lastRepairAtValue as? Date {
            lastRepairDate = date
        } else if let dateString = lastRepairAtValue as? String {
            lastRepairDate = Self.sqliteDateFormatter.date(from: dateString)
        } else {
            lastRepairDate = nil
        }

        return TranscriptSegment(
            id: id,
            transcriptId: transcriptId,
            text: text,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            confidence: confidence,
            speaker: speaker,
            language: language,
            lastRepairModel: lastRepairModel,
            lastRepairAt: lastRepairDate
        )
    }

    private func addMediaKindColumnIfNeeded(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(tracks)")
        let existingColumns = Set(rows.compactMap { $0["name"] as? String })

        guard !existingColumns.contains("media_kind") else { return }

        try database.execute(sql: "ALTER TABLE tracks ADD COLUMN media_kind TEXT NOT NULL DEFAULT 'audio'")
    }

    private func addTranscriptRepairColumnsIfNeeded(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(transcript_segments)")
        let existingColumns = Set(rows.compactMap { $0["name"] as? String })

        if !existingColumns.contains("last_repair_model") {
            try database.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN last_repair_model TEXT")
        }

        if !existingColumns.contains("last_repair_at") {
            try database.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN last_repair_at DATETIME")
        }
    }
    
    private func addTranscriptionJobParagraphColumnsIfNeeded(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(transcription_jobs)")
        let existingColumns = Set(rows.compactMap { $0["name"] as? String })

        if !existingColumns.contains("total_paragraphs") {
            try database.execute(sql: "ALTER TABLE transcription_jobs ADD COLUMN total_paragraphs INTEGER")
        }

        if !existingColumns.contains("processed_paragraphs") {
            try database.execute(sql: "ALTER TABLE transcription_jobs ADD COLUMN processed_paragraphs INTEGER")
        }

        if !existingColumns.contains("pending_paragraphs") {
            try database.execute(sql: "ALTER TABLE transcription_jobs ADD COLUMN pending_paragraphs INTEGER")
        }
    }

    private func addTrackCharacterCountColumnIfNeeded(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(tracks)")
        let existingColumns = Set(rows.compactMap { $0["name"] as? String })
        if !existingColumns.contains("character_count") {
            try database.execute(sql: "ALTER TABLE tracks ADD COLUMN character_count INTEGER")
        }
    }
    
    // MARK: - Listening Statistics Operations
    
    /// Save a listening statistic
    func saveListeningStatistic(_ statistic: ListeningStatistic) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { db in
            try db.execute(sql:
                """
                INSERT INTO listening_statistics (
                    id, track_id, collection_id,
                    start_time, end_time, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    statistic.id.uuidString,
                    statistic.trackId.uuidString,
                    statistic.collectionId.uuidString,
                    statistic.startTime,
                    statistic.endTime,
                    statistic.createdAt
                ]
            )
        }
    }
    
    /// Load total listening duration across all collections
    func loadTotalListeningDuration() throws -> TimeInterval {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT start_time, end_time FROM listening_statistics
                """
            )
            
            var totalDuration: TimeInterval = 0
            for row in rows {
                if let startTimeValue = row["start_time"],
                   let endTimeValue = row["end_time"] {
                    let startTime: Date
                    let endTime: Date
                    
                    if let date = startTimeValue as? Date {
                        startTime = date
                    } else if let dateString = startTimeValue as? String,
                              let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                        startTime = parsedDate
                    } else {
                        continue
                    }
                    
                    if let date = endTimeValue as? Date {
                        endTime = date
                    } else if let dateString = endTimeValue as? String,
                              let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                        endTime = parsedDate
                    } else {
                        continue
                    }
                    
                    totalDuration += endTime.timeIntervalSince(startTime)
                }
            }
            
            return totalDuration
        }
    }
    
    /// Load listening duration per collection
    func loadListeningDurationsByCollection() throws -> [UUID: TimeInterval] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT collection_id, start_time, end_time FROM listening_statistics
                """
            )
            
            var durations: [UUID: TimeInterval] = [:]
            
            for row in rows {
                guard let collectionIdStr = row["collection_id"] as? String,
                      let collectionId = UUID(uuidString: collectionIdStr),
                      let startTimeValue = row["start_time"],
                      let endTimeValue = row["end_time"] else {
                    continue
                }
                
                let startTime: Date
                let endTime: Date
                
                if let date = startTimeValue as? Date {
                    startTime = date
                } else if let dateString = startTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    startTime = parsedDate
                } else {
                    continue
                }
                
                if let date = endTimeValue as? Date {
                    endTime = date
                } else if let dateString = endTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    endTime = parsedDate
                } else {
                    continue
                }
                
                let duration = endTime.timeIntervalSince(startTime)
                durations[collectionId, default: 0] += duration
            }
            
            return durations
        }
    }
    
    /// Delete listening statistics for a collection
    func deleteStatistics(for collectionId: UUID) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM listening_statistics WHERE collection_id = ?",
                arguments: [collectionId.uuidString]
            )
        }
    }
    
    /// Load daily listening durations for a date range
    func loadDailyListeningDurations(from startDate: Date, to endDate: Date) throws -> [Date: TimeInterval] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT start_time, end_time 
                FROM listening_statistics 
                WHERE start_time >= ? AND start_time <= ?
                """,
                arguments: [startDate, endDate]
            )
            
            var dailyDurations: [Date: TimeInterval] = [:]
            let calendar = Calendar.current
            
            for row in rows {
                guard let startTimeValue = row["start_time"],
                      let endTimeValue = row["end_time"] else { continue }
                
                let startTime: Date
                let endTime: Date
                
                if let date = startTimeValue as? Date {
                    startTime = date
                } else if let dateString = startTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    startTime = parsedDate
                } else { continue }
                
                if let date = endTimeValue as? Date {
                    endTime = date
                } else if let dateString = endTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    endTime = parsedDate
                } else { continue }
                
                let duration = endTime.timeIntervalSince(startTime)
                let startOfDay = calendar.startOfDay(for: startTime)
                dailyDurations[startOfDay, default: 0] += duration
            }
            
            return dailyDurations
        }
    }

    /// Load collection listening durations between two dates
    func loadListeningDurationsByCollection(from startDate: Date, to endDate: Date) throws -> [UUID: TimeInterval] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT collection_id, start_time, end_time
                FROM listening_statistics
                WHERE start_time >= ? AND start_time <= ?
                """,
                arguments: [startDate, endDate]
            )

            var durations: [UUID: TimeInterval] = [:]

            for row in rows {
                guard let collectionIdStr = row["collection_id"] as? String,
                      let collectionId = UUID(uuidString: collectionIdStr),
                      let startTimeValue = row["start_time"],
                      let endTimeValue = row["end_time"] else {
                    continue
                }

                let startTime: Date
                let endTime: Date

                if let date = startTimeValue as? Date {
                    startTime = date
                } else if let dateString = startTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    startTime = parsedDate
                } else {
                    continue
                }

                if let date = endTimeValue as? Date {
                    endTime = date
                } else if let dateString = endTimeValue as? String,
                          let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                    endTime = parsedDate
                } else {
                    continue
                }

                let duration = endTime.timeIntervalSince(startTime)
                durations[collectionId, default: 0] += duration
            }

            return durations
        }
    }
    
    /// Get the earliest listening statistics date
    func getEarliestListeningDate() throws -> Date? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT MIN(start_time) as earliest FROM listening_statistics"
            ) else {
                return nil
            }
            
            let earliestValue = row["earliest"]
            if let date = earliestValue as? Date {
                return date
            } else if let dateString = earliestValue as? String,
                      let parsedDate = GRDBDatabaseManager.sqliteDateFormatter.date(from: dateString) {
                return parsedDate
            }
            return nil
        }
    }

    /// Load listening statistics summary
    func loadListeningStatisticsSummary() throws -> ListeningStatisticsSummary {
        let totalDuration = try loadTotalListeningDuration()
        let collectionDurations = try loadListeningDurationsByCollection()
        
        // Load daily stats for the last 70 days
        let calendar = Calendar.current
        let now = Date()
        let daysBack = 70
        let lookbackStart = calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
        let dailyDurations = try loadDailyListeningDurations(from: lookbackStart, to: now)

        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let recentWeekCollectionDurations = try loadListeningDurationsByCollection(from: sevenDaysAgo, to: now)
        let weeklyDurations = aggregateWeeklyDurations(
            dailyDurations: dailyDurations,
            calendar: calendar,
            referenceDate: now,
            weeks: 6
        )

        return ListeningStatisticsSummary(
            totalDuration: totalDuration,
            collectionDurations: collectionDurations,
            dailyDurations: dailyDurations,
            recentWeekCollectionDurations: recentWeekCollectionDurations,
            weeklyDurations: weeklyDurations
        )
    }

    private func aggregateWeeklyDurations(
        dailyDurations: [Date: TimeInterval],
        calendar: Calendar,
        referenceDate: Date,
        weeks: Int
    ) -> [WeeklyListeningDuration] {
        guard weeks > 0 else { return [] }

        let currentWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: referenceDate))
            ?? calendar.startOfDay(for: referenceDate)
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeekStart)
            ?? currentWeekStart

        var groupedDurations: [Date: TimeInterval] = [:]

        for (day, duration) in dailyDurations {
            let normalizedDay = calendar.startOfDay(for: day)
            guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: normalizedDay)) else {
                continue
            }
            groupedDurations[weekStart, default: 0] += duration
        }

        var weeklyDurations: [WeeklyListeningDuration] = []

        for offset in 0..<weeks {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeekStart),
                  let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
                continue
            }
            let total = groupedDurations[weekStart] ?? 0
            weeklyDurations.append(
                WeeklyListeningDuration(
                    startDate: weekStart,
                    endDate: weekEnd,
                    totalDuration: total
                )
            )
        }

        return weeklyDurations
    }
}


// MARK: - Type String Extensions

extension AudiobookCollection.Source {
    var typeString: String {
        switch self {
        case .baiduNetdisk: return "baiduNetdisk"
        case .local: return "local"
        case .external: return "external"
        case .ephemeralBaidu: return "ephemeralBaidu"
        case .ebook: return "ebook"
        }
    }

    func payloadJSON() -> String {
        var payload: [String: Any] = [:]

        switch self {
        case let .baiduNetdisk(folderPath, tokenScope):
            payload = ["folderPath": folderPath, "tokenScope": tokenScope]

        case let .local(directoryBookmark):
            payload = ["directoryBookmark": directoryBookmark.base64EncodedString()]

        case let .external(description):
            payload = ["description": description]

        case let .ephemeralBaidu(path):
            payload = ["ephemeralPath": path]

        case let .ebook(importedDate):
            payload = ["importedDate": importedDate.timeIntervalSince1970]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}

extension AudiobookTrack.Location {
    var typeString: String {
        switch self {
        case .baidu: return "baidu"
        case .local: return "local"
        case .external: return "external"
        case .text: return "text"
        case .cachedText: return "cachedText"
        }
    }

    func payloadJSON() -> String {
        var payload: [String: Any] = [:]

        switch self {
        case let .baidu(fsId, path):
            payload = ["fsId": fsId, "path": path]

        case let .local(urlBookmark):
            payload = ["urlBookmark": urlBookmark.base64EncodedString()]

        case let .external(url):
            payload = ["url": url.absoluteString]

        case let .text(content):
            payload = ["content": content]

        case let .cachedText(filename):
            payload = ["filename": filename]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}

extension CollectionCover.Kind {
    var typeString: String {
        switch self {
        case .solid: return "solid"
        case .image: return "image"
        case .remote: return "remote"
        }
    }

    func dataJSON() -> String {
        var payload: [String: Any] = [:]

        switch self {
        case let .solid(colorHex):
            payload = ["colorHex": colorHex]

        case let .image(relativePath):
            payload = ["relativePath": relativePath]

        case let .remote(url):
            payload = ["url": url.absoluteString]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}


// MARK: - Error Types

enum DatabaseError: LocalizedError {
    case initializationFailed(String)
    case queryFailed(String)
    case saveFailed(String)
    case loadFailed(String)
    case deleteFailed(String)
    case notFound(String)
    case inconsistentData(String)

    var errorDescription: String? {
        switch self {
        case let .initializationFailed(msg):
            return "Database initialization failed: \(msg)"
        case let .queryFailed(msg):
            return "Query failed: \(msg)"
        case let .saveFailed(msg):
            return "Save operation failed: \(msg)"
        case let .loadFailed(msg):
            return "Load operation failed: \(msg)"
        case let .deleteFailed(msg):
            return "Delete operation failed: \(msg)"
        case let .notFound(msg):
            return "Not found: \(msg)"
        case let .inconsistentData(msg):
            return "Data inconsistency: \(msg)"
        }
    }
}
