import Foundation

/// Schema for track summary persistence
enum TrackSummaryDatabaseSchema {
    static let createTableSQL = """
    -- Track summaries table
    CREATE TABLE IF NOT EXISTS track_summaries (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        transcript_id TEXT NOT NULL,
        language TEXT NOT NULL DEFAULT 'en',
        summary_title TEXT,
        summary_body TEXT,
        keywords_json TEXT,
        section_count INTEGER NOT NULL DEFAULT 0,
        model_identifier TEXT,
        generated_at DATETIME,
        status TEXT NOT NULL DEFAULT 'idle',
        error_message TEXT,
        last_job_id TEXT,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        UNIQUE(track_id),
        FOREIGN KEY (track_id) REFERENCES tracks(id),
        FOREIGN KEY (transcript_id) REFERENCES transcripts(id)
    );

    -- Track summary sections table
    CREATE TABLE IF NOT EXISTS track_summary_sections (
        id TEXT PRIMARY KEY,
        track_summary_id TEXT NOT NULL,
        order_index INTEGER NOT NULL,
        start_time_ms INTEGER NOT NULL,
        end_time_ms INTEGER,
        title TEXT,
        summary TEXT NOT NULL,
        keywords_json TEXT,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        FOREIGN KEY (track_summary_id) REFERENCES track_summaries(id)
    );

    CREATE INDEX IF NOT EXISTS idx_track_summaries_track_id
        ON track_summaries(track_id);
    CREATE INDEX IF NOT EXISTS idx_track_summaries_status
        ON track_summaries(status);
    CREATE INDEX IF NOT EXISTS idx_track_summary_sections_parent_order
        ON track_summary_sections(track_summary_id, order_index);
    """
}
