import Foundation

/// Database schema definition for GRDB
enum DatabaseSchema {
    /// Current schema version
    static let currentVersion = 1

    /// SQL for creating tables
    static let createTableSQL = """
    -- Collections table
    CREATE TABLE IF NOT EXISTS collections (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        author TEXT,
        description TEXT,
        cover_kind TEXT NOT NULL,
        cover_data TEXT,
        cover_dominant_color TEXT,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        source_type TEXT NOT NULL,
        source_payload TEXT NOT NULL,
        last_played_track_id TEXT
    );

    -- Tracks table
    CREATE TABLE IF NOT EXISTS tracks (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        filename TEXT NOT NULL,
        location_type TEXT NOT NULL,
        location_payload TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        duration REAL,
        track_number INTEGER NOT NULL,
        checksum TEXT,
        metadata_json TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        favorited_at DATETIME,
        FOREIGN KEY (collection_id) REFERENCES collections(id)
    );

    -- Playback states table
    CREATE TABLE IF NOT EXISTS playback_states (
        track_id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL,
        position REAL NOT NULL,
        duration REAL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id),
        FOREIGN KEY (collection_id) REFERENCES collections(id)
    );

    -- Tags table
    CREATE TABLE IF NOT EXISTS tags (
        collection_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY (collection_id, tag),
        FOREIGN KEY (collection_id) REFERENCES collections(id)
    );

    -- Schema state table
    CREATE TABLE IF NOT EXISTS schema_state (
        version INTEGER PRIMARY KEY CHECK (version = 1)
    );

    -- Create indexes for common queries
    CREATE INDEX IF NOT EXISTS idx_tracks_collection_id ON tracks(collection_id);
    CREATE INDEX IF NOT EXISTS idx_tracks_collection_track_number ON tracks(collection_id, track_number);
    CREATE INDEX IF NOT EXISTS idx_playback_states_collection_id ON playback_states(collection_id);
    CREATE INDEX IF NOT EXISTS idx_tracks_is_favorite ON tracks(is_favorite);
    CREATE INDEX IF NOT EXISTS idx_playback_states_updated_at ON playback_states(updated_at);
    """

    /// Create and initialize the database
    static func initialize(dbURL: URL) throws {
        // Database initialization will be handled by GRDB migrator
        // This is here as a reference for the schema structure
    }
}

// MARK: - DTO Models for Database Operations

/// Data Transfer Object for collections in the database
struct CollectionRow: Codable {
    let id: String
    let title: String
    let author: String?
    let description: String?
    let coverKind: String
    let coverData: String?
    let coverDominantColor: String?
    let createdAt: Date
    let updatedAt: Date
    let sourceType: String
    let sourcePayload: String
    let lastPlayedTrackId: String?
}

/// Data Transfer Object for tracks in the database
struct TrackRow: Codable {
    let id: String
    let collectionId: String
    let displayName: String
    let filename: String
    let locationType: String
    let locationPayload: String
    let fileSize: Int64
    let duration: TimeInterval?
    let trackNumber: Int
    let checksum: String?
    let metadataJson: String?
    let isFavorite: Bool
    let favoritedAt: Date?
}

/// Data Transfer Object for playback states in the database
struct PlaybackStateRow: Codable {
    let trackId: String
    let collectionId: String
    let position: TimeInterval
    let duration: TimeInterval?
    let updatedAt: Date
}

/// Data Transfer Object for tags in the database
struct TagRow: Codable {
    let collectionId: String
    let tag: String
}
