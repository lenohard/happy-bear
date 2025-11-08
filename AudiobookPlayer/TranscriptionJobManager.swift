import Foundation
import GRDB

// MARK: - Transcription Job Management Extension

/// Extension to GRDBDatabaseManager adding comprehensive job tracking
extension GRDBDatabaseManager {

    // MARK: - Job Creation & Retrieval

    /// Create a new transcription job record
    func createTranscriptionJob(
        trackId: String,
        sonioxJobId: String
    ) throws -> TranscriptionJob {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let job = TranscriptionJob(
            trackId: trackId,
            sonioxJobId: sonioxJobId,
            status: "queued"
        )

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO transcription_jobs (
                    id, track_id, soniox_job_id, status,
                    created_at, retry_count, last_attempt_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    job.id,
                    job.trackId,
                    job.sonioxJobId,
                    job.status,
                    Self.sqliteDateFormatter.string(from: job.createdAt),
                    job.retryCount,
                    NSNull()
                ]
            )
        }

        return job
    }

    /// Load a transcription job by ID
    func loadTranscriptionJob(jobId: String) throws -> TranscriptionJob? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transcription_jobs WHERE id = ?",
                arguments: [jobId]
            ) else {
                return nil
            }

            return try reconstructTranscriptionJob(row: row)
        }
    }

    /// Load a transcription job by Soniox job ID
    func loadTranscriptionJobBySonioxId(_ sonioxJobId: String) throws -> TranscriptionJob? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transcription_jobs WHERE soniox_job_id = ?",
                arguments: [sonioxJobId]
            ) else {
                return nil
            }

            return try reconstructTranscriptionJob(row: row)
        }
    }

    /// Load all active transcription jobs (not completed or failed)
    func loadActiveTranscriptionJobs() throws -> [TranscriptionJob] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM transcription_jobs
                    WHERE status NOT IN ('completed', 'failed')
                    ORDER BY created_at DESC
                    """
            )

            return try rows.compactMap { try reconstructTranscriptionJob(row: $0) }
        }
    }

    /// Load jobs that need retry (failed with retries remaining)
    func loadJobsNeedingRetry(maxRetries: Int = 3) throws -> [TranscriptionJob] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM transcription_jobs
                    WHERE status = 'failed'
                    AND retry_count < ?
                    ORDER BY last_attempt_at ASC
                    """,
                arguments: [maxRetries]
            )

            return try rows.compactMap { try reconstructTranscriptionJob(row: $0) }
        }
    }

    // MARK: - Job Status Updates

    /// Update job status and record the attempt time
    func updateJobStatus(
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
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    /// Mark job as completed and record completion time
    func markJobCompleted(jobId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                UPDATE transcription_jobs
                SET status = 'completed', completed_at = ?, progress = 1.0
                WHERE id = ?
                """,
                arguments: [
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    /// Mark job as failed with error message and increment retry count
    func markJobFailed(jobId: String, errorMessage: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            // Get current retry count
            guard let currentJob = try Row.fetchOne(
                db,
                sql: "SELECT retry_count FROM transcription_jobs WHERE id = ?",
                arguments: [jobId]
            ) else {
                throw DatabaseError.queryFailed("Job not found")
            }

            let currentRetryCount = (currentJob["retry_count"] as? Int) ?? 0

            // Update with incremented retry count
            try db.execute(sql: """
                UPDATE transcription_jobs
                SET status = 'failed',
                    error_message = ?,
                    retry_count = ?,
                    last_attempt_at = ?
                WHERE id = ?
                """,
                arguments: [
                    errorMessage,
                    currentRetryCount + 1,
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    /// Reset job for retry (clears error and sets status back to queued)
    func resetJobForRetry(jobId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                UPDATE transcription_jobs
                SET status = 'queued', error_message = NULL
                WHERE id = ?
                """,
                arguments: [jobId]
            )
        }
    }

    // MARK: - Progress Tracking

    /// Update job progress
    func updateJobProgress(jobId: String, progress: Double) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                UPDATE transcription_jobs
                SET progress = ?
                WHERE id = ?
                """,
                arguments: [
                    progress,
                    jobId
                ]
            )
        }
    }

    // MARK: - Cleanup

    /// Delete a transcription job (typically after completion confirmation)
    func deleteTranscriptionJob(jobId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: "DELETE FROM transcription_jobs WHERE id = ?", arguments: [jobId])
        }
    }

    /// Delete completed jobs older than the specified date
    func deleteCompletedJobsBefore(_ date: Date) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { db in
            try db.execute(sql: """
                DELETE FROM transcription_jobs
                WHERE status = 'completed' AND completed_at < ?
                """,
                arguments: [Self.sqliteDateFormatter.string(from: date)]
            )
        }
    }

    // MARK: - Helper Methods

    private func reconstructTranscriptionJob(row: Row) throws -> TranscriptionJob? {
        guard let id = row["id"] as? String,
              let trackId = row["track_id"] as? String,
              let sonioxJobId = row["soniox_job_id"] as? String,
              let status = row["status"] as? String else {
            return nil
        }

        let progress = row["progress"] as? Double
        let errorMessage = row["error_message"] as? String
        let retryCount = (row["retry_count"] as? Int) ?? 0

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

        let completedAtValue = row["completed_at"]
        var completedAt: Date? = nil
        if let date = completedAtValue as? Date {
            completedAt = date
        } else if let dateString = completedAtValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            completedAt = parsedDate
        }

        let lastAttemptValue = row["last_attempt_at"]
        var lastAttempt: Date? = nil
        if let date = lastAttemptValue as? Date {
            lastAttempt = date
        } else if let dateString = lastAttemptValue as? String,
                  let parsedDate = Self.sqliteDateFormatter.date(from: dateString) {
            lastAttempt = parsedDate
        }

        return TranscriptionJob(
            id: id,
            trackId: trackId,
            sonioxJobId: sonioxJobId,
            status: status,
            progress: progress,
            createdAt: createdAt,
            completedAt: completedAt,
            errorMessage: errorMessage,
            retryCount: retryCount,
            lastAttemptAt: lastAttempt
        )
    }
}
