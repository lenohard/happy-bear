import Foundation

/// Database schema extensions for AI generation job tracking
enum AIGenerationDatabaseSchema {
    /// SQL for creating AI generation job tables
    static let createTableSQL = """
    -- AI generation jobs table
    CREATE TABLE IF NOT EXISTS ai_generation_jobs (
        id TEXT PRIMARY KEY,
        job_type TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        model_id TEXT,
        track_id TEXT,
        transcript_id TEXT,
        source_context TEXT,
        display_name TEXT,
        system_prompt TEXT,
        user_prompt TEXT,
        payload_json TEXT,
        metadata_json TEXT,
        streamed_output TEXT,
        final_output TEXT,
        usage_json TEXT,
        progress REAL,
        error_message TEXT,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        completed_at DATETIME,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at DATETIME
    );

    CREATE INDEX IF NOT EXISTS idx_ai_jobs_status_created_at
        ON ai_generation_jobs(status, created_at);
    CREATE INDEX IF NOT EXISTS idx_ai_jobs_type_created_at
        ON ai_generation_jobs(job_type, created_at);
    CREATE INDEX IF NOT EXISTS idx_ai_jobs_track_id
        ON ai_generation_jobs(track_id);
    CREATE INDEX IF NOT EXISTS idx_ai_jobs_transcript_id
        ON ai_generation_jobs(transcript_id);
    """
}
