import Foundation

/// Schema for track chat persistence
enum TrackChatDatabaseSchema {
    static let createTableSQL = """
    -- Track chat sessions
    CREATE TABLE IF NOT EXISTS track_chat_sessions (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        collection_id TEXT,
        title TEXT,
        model_id TEXT,
        context_flags TEXT,
        context_snapshot TEXT,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id)
    );

    -- Track chat messages
    CREATE TABLE IF NOT EXISTS track_chat_messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        metadata_json TEXT,
        created_at DATETIME NOT NULL,
        FOREIGN KEY (session_id) REFERENCES track_chat_sessions(id)
    );

    -- Track chat defaults
    CREATE TABLE IF NOT EXISTS track_chat_defaults (
        track_id TEXT PRIMARY KEY,
        context_flags TEXT,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id)
    );

    CREATE INDEX IF NOT EXISTS idx_track_chat_sessions_track_updated_at
        ON track_chat_sessions(track_id, updated_at);
    CREATE INDEX IF NOT EXISTS idx_track_chat_messages_session_created_at
        ON track_chat_messages(session_id, created_at);
    """
}
