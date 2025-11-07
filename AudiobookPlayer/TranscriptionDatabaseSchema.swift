import Foundation

/// Database schema extensions for transcription features
enum TranscriptionDatabaseSchema {
    /// Current schema version for transcription tables
    static let transcriptionVersion = 1

    /// SQL for creating transcription-related tables
    static let createTableSQL = """
    -- Transcripts table
    CREATE TABLE IF NOT EXISTS transcripts (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        collection_id TEXT NOT NULL,
        language TEXT NOT NULL DEFAULT 'en',
        full_text TEXT NOT NULL,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        job_status TEXT NOT NULL DEFAULT 'pending',
        job_id TEXT,
        error_message TEXT,
        FOREIGN KEY (track_id) REFERENCES tracks(id),
        FOREIGN KEY (collection_id) REFERENCES collections(id)
    );

    -- Transcript segments table (for detailed timing and speaker info)
    CREATE TABLE IF NOT EXISTS transcript_segments (
        id TEXT PRIMARY KEY,
        transcript_id TEXT NOT NULL,
        text TEXT NOT NULL,
        start_time_ms INTEGER NOT NULL,
        end_time_ms INTEGER NOT NULL,
        confidence REAL,
        speaker TEXT,
        language TEXT,
        FOREIGN KEY (transcript_id) REFERENCES transcripts(id)
    );

    -- Transcription jobs table (for tracking async transcription state)
    CREATE TABLE IF NOT EXISTS transcription_jobs (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        soniox_job_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        progress REAL,
        created_at DATETIME NOT NULL,
        completed_at DATETIME,
        error_message TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at DATETIME,
        FOREIGN KEY (track_id) REFERENCES tracks(id)
    );

    -- Create indexes for common queries
    CREATE INDEX IF NOT EXISTS idx_transcripts_track_id ON transcripts(track_id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_collection_id ON transcripts(collection_id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_job_status ON transcripts(job_status);
    CREATE INDEX IF NOT EXISTS idx_transcript_segments_transcript_id ON transcript_segments(transcript_id);
    CREATE INDEX IF NOT EXISTS idx_transcription_jobs_track_id ON transcription_jobs(track_id);
    CREATE INDEX IF NOT EXISTS idx_transcription_jobs_status ON transcription_jobs(status);
    CREATE INDEX IF NOT EXISTS idx_transcription_jobs_soniox_job_id ON transcription_jobs(soniox_job_id);
    """

    /// Initialize transcription tables
    static func initialize(dbURL: URL) throws {
        // Database initialization will be handled by GRDB migrator
        // This is here as a reference for the schema structure
    }
}
