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
        let db = try DatabaseQueue(path: dbURL.path)
        self.db = db
        print("[GRDB] DatabaseQueue created successfully")

        // Create schema
        print("[GRDB] Creating schema...")
        try db.write { db in
            // Create all tables
            print("[GRDB] Executing createTableSQL...")
            try db.execute(sql: DatabaseSchema.createTableSQL)
            print("[GRDB] Schema tables created")

            // Create transcription tables
            print("[GRDB] Executing transcription schema...")
            try db.execute(sql: TranscriptionDatabaseSchema.createTableSQL)
            print("[GRDB] Transcription tables created")

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
                        is_favorite, favorited_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        track.isFavorite ? 1 : 0,
                        track.favoritedAt
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
                tagRows: tagRows
            )
        }
    }

    /// Load all collections
    func loadAllCollections() throws -> [AudiobookCollection] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        print("[GRDB] Starting loadAllCollections")

        return try db.read { db in
            print("[GRDB] Fetching all collection rows...")
            let collectionRows = try Row.fetchAll(db, sql: "SELECT * FROM collections")
            print("[GRDB] Found \(collectionRows.count) collection rows in database")

            var collections: [AudiobookCollection] = []

            for collectionRow in collectionRows {
                guard let collectionId = collectionRow["id"] as? String,
                      let _ = UUID(uuidString: collectionId) else {
                    print("[GRDB] Invalid collection ID: \(collectionRow["id"] as? String ?? "unknown")")
                    continue
                }

                print("[GRDB] Loading collection: \(collectionId)")

                let trackRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM tracks WHERE collection_id = ? ORDER BY track_number",
                    arguments: [collectionId]
                )
                print("[GRDB] Found \(trackRows.count) tracks for collection \(collectionId)")

                // Debug: Check for favorite status in raw rows
                let favoriteCount = trackRows.filter { (($0["is_favorite"] as? Int) ?? 0) == 1 }.count
                if favoriteCount > 0 {
                    print("[FAVORITES-DB] Found \(favoriteCount) favorite tracks in raw database rows")
                }

                let playbackRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM playback_states WHERE collection_id = ?",
                    arguments: [collectionId]
                )

                let tagRows = try Row.fetchAll(
                    db,
                    sql: "SELECT tag FROM tags WHERE collection_id = ?",
                    arguments: [collectionId]
                )

                if let collection = try reconstructCollection(
                    collectionRow: collectionRow,
                    trackRows: trackRows,
                    playbackRows: playbackRows,
                    tagRows: tagRows
                ) {
                    collections.append(collection)
                    print("[GRDB] Successfully reconstructed collection: \(collection.title)")
                } else {
                    print("[GRDB] Failed to reconstruct collection from row")
                }
            }

            print("[GRDB] Returning \(collections.count) collections")
            return collections
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
                    is_favorite = ?,
                    favorited_at = ?
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
                    track.isFavorite ? 1 : 0,
                    track.favoritedAt,
                    track.id.uuidString,
                    collectionId.uuidString
                ]
            )
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
        tagRows: [Row]
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
            tags: tags
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
            isFavorite: isFavorite,
            favoritedAt: favoritedAt
        )
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

        default:
            throw DatabaseError.inconsistentData("Unknown location type: \(type)")
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
            return jobStatus == "complete"
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
                        confidence, speaker, language
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id,
                        transcriptId,
                        segment.text,
                        segment.startTimeMs,
                        segment.endTimeMs,
                        segment.confidence,
                        segment.speaker,
                        segment.language
                    ]
                )
            }
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

        return TranscriptSegment(
            id: id,
            transcriptId: transcriptId,
            text: text,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            confidence: confidence,
            speaker: speaker,
            language: language
        )
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
