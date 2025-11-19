import Foundation
import GRDB

// MARK: - AI Generation Job Management Extension

extension GRDBDatabaseManager {

    // MARK: Creation

    func createAIGenerationJob(
        type: AIGenerationJob.JobType,
        modelId: String?,
        trackId: String? = nil,
        transcriptId: String? = nil,
        sourceContext: String? = nil,
        displayName: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String? = nil,
        payloadJSON: String? = nil,
        metadataJSON: String? = nil,
        initialStatus: AIGenerationJob.Status = .queued
    ) throws -> AIGenerationJob {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let now = Date()
        let job = AIGenerationJob(
            type: type,
            status: initialStatus,
            modelId: modelId,
            trackId: trackId,
            transcriptId: transcriptId,
            sourceContext: sourceContext,
            displayName: displayName,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            payloadJSON: payloadJSON,
            metadataJSON: metadataJSON,
            createdAt: now,
            updatedAt: now
        )

        try db.write { database in
            try database.execute(sql: """
                INSERT INTO ai_generation_jobs (
                    id, job_type, status, model_id, track_id, transcript_id,
                    source_context, display_name, system_prompt, user_prompt,
                    payload_json, metadata_json, streamed_output, final_output, usage_json,
                    progress, error_message, created_at, updated_at,
                    completed_at, retry_count, last_attempt_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    job.id,
                    job.type.rawValue,
                    job.status.rawValue,
                    job.modelId,
                    job.trackId,
                    job.transcriptId,
                    job.sourceContext,
                    job.displayName,
                    job.systemPrompt,
                    job.userPrompt,
                    job.payloadJSON,
                    job.metadataJSON,
                    job.streamedOutput,
                    job.finalOutput,
                    job.usageJSON,
                    job.progress,
                    job.errorMessage,
                    Self.sqliteDateFormatter.string(from: job.createdAt),
                    Self.sqliteDateFormatter.string(from: job.updatedAt),
                    job.completedAt.map { Self.sqliteDateFormatter.string(from: $0) },
                    job.retryCount,
                    job.lastAttemptAt.map { Self.sqliteDateFormatter.string(from: $0) }
                ]
            )
        }

        return job
    }

    // MARK: Loading

    func loadAIGenerationJob(jobId: String) throws -> AIGenerationJob? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM ai_generation_jobs WHERE id = ?",
                arguments: [jobId]
            ) else {
                return nil
            }

            return try reconstructAIGenerationJob(row: row)
        }
    }

    func loadActiveAIGenerationJobs() throws -> [AIGenerationJob] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM ai_generation_jobs
                    WHERE status NOT IN ('completed', 'failed', 'canceled')
                    ORDER BY created_at ASC
                """
            )

            return try rows.compactMap { try reconstructAIGenerationJob(row: $0) }
        }
    }

    func loadRecentAIGenerationJobs(limit: Int = 50) throws -> [AIGenerationJob] {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM ai_generation_jobs
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: [limit]
            )

            return try rows.compactMap { try reconstructAIGenerationJob(row: $0) }
        }
    }

    func dequeueNextQueuedAIGenerationJob() throws -> AIGenerationJob? {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT * FROM ai_generation_jobs
                    WHERE status = 'queued'
                    ORDER BY created_at ASC
                    LIMIT 1
                """
            ) else {
                return nil
            }

            guard let job = try reconstructAIGenerationJob(row: row) else {
                return nil
            }

            let nowString = Self.sqliteDateFormatter.string(from: Date())
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = 'running', updated_at = ?, last_attempt_at = ?
                WHERE id = ?
                """,
                arguments: [nowString, nowString, job.id]
            )

            return job.updating(status: .running, updatedAt: Date())
        }
    }

    // MARK: Updates

    func updateAIGenerationJobStatus(
        jobId: String,
        status: AIGenerationJob.Status,
        progress: Double? = nil
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = ?, progress = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status.rawValue,
                    progress,
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    func updateAIGenerationJobStream(jobId: String, streamedOutput: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET streamed_output = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    streamedOutput,
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    func updateAIGenerationJobMetadata(jobId: String, metadataJSON: String?) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET metadata_json = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    metadataJSON,
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    func markAIGenerationJobCompleted(
        jobId: String,
        finalOutput: String?,
        usageJSON: String?
    ) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let now = Self.sqliteDateFormatter.string(from: Date())
        try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = 'completed', final_output = ?, usage_json = ?, completed_at = ?, updated_at = ?, progress = 1.0
                WHERE id = ?
                """,
                arguments: [
                    finalOutput,
                    usageJSON,
                    now,
                    now,
                    jobId
                ]
            )
        }
    }

    func markAIGenerationJobFailed(jobId: String, errorMessage: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = 'failed', error_message = ?, retry_count = retry_count + 1, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    errorMessage,
                    Self.sqliteDateFormatter.string(from: Date()),
                    jobId
                ]
            )
        }
    }

    func deleteAIGenerationJob(jobId: String) throws {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            try database.execute(sql: "DELETE FROM ai_generation_jobs WHERE id = ?", arguments: [jobId])
        }
    }

    func cancelQueuedAIGenerationJob(jobId: String) throws -> Bool {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.write { database in
            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = 'canceled', updated_at = ?
                WHERE id = ? AND status = 'queued'
                """,
                arguments: [Self.sqliteDateFormatter.string(from: Date()), jobId]
            )
            return database.changesCount > 0
        }
    }

    func failInterruptedAIGenerationJobs(
        interruptionReason: String,
        staleBefore: Date? = nil
    ) throws -> Int {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.write { database in
            var whereClause = "status IN ('running', 'streaming')"
            var filterArguments: [DatabaseValueConvertible?] = []
            if let staleBefore {
                whereClause += " AND updated_at <= ?"
                let cutoff = Self.sqliteDateFormatter.string(from: staleBefore)
                filterArguments.append(cutoff)
            }

            let countSQL = "SELECT COUNT(*) FROM ai_generation_jobs WHERE \(whereClause)"
            let count = try Int.fetchOne(
                database,
                sql: countSQL,
                arguments: StatementArguments(filterArguments)
            ) ?? 0

            if count == 0 {
                return 0
            }

            let nowString = Self.sqliteDateFormatter.string(from: Date())
            var updateArguments: [DatabaseValueConvertible?] = [interruptionReason, nowString]
            updateArguments.append(contentsOf: filterArguments)

            try database.execute(
                sql: """
                UPDATE ai_generation_jobs
                SET status = 'failed',
                    error_message = ?,
                    updated_at = ?,
                    completed_at = NULL,
                    progress = NULL,
                    retry_count = retry_count + 1
                WHERE \(whereClause)
                """,
                arguments: StatementArguments(updateArguments)
            )

            return count
        }
    }

    func hasQueuedAIGenerationJobs() throws -> Bool {
        guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let count = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM ai_generation_jobs WHERE status = 'queued'"
            ) ?? 0
            return count > 0
        }
    }

    // MARK: Helpers

    private func reconstructAIGenerationJob(row: Row) throws -> AIGenerationJob? {
        guard
            let id = row["id"] as? String,
            let typeString = row["job_type"] as? String,
            let type = AIGenerationJob.JobType(rawValue: typeString),
            let statusString = row["status"] as? String,
            let status = AIGenerationJob.Status(rawValue: statusString)
        else {
            return nil
        }

        let modelId = row["model_id"] as? String
        let trackId = row["track_id"] as? String
        let transcriptId = row["transcript_id"] as? String
        let sourceContext = row["source_context"] as? String
        let displayName = row["display_name"] as? String
        let systemPrompt = row["system_prompt"] as? String
        let userPrompt = row["user_prompt"] as? String
        let payloadJSON = row["payload_json"] as? String
        let metadataJSON = row["metadata_json"] as? String
        let streamedOutput = row["streamed_output"] as? String
        let finalOutput = row["final_output"] as? String
        let usageJSON = row["usage_json"] as? String
        let progress = row["progress"] as? Double
        let errorMessage = row["error_message"] as? String
        let retryCount = (row["retry_count"] as? Int) ?? 0

        let createdAt = parseSQLiteDate(row["created_at"])
        let updatedAt = parseSQLiteDate(row["updated_at"])
        let completedAt = parseSQLiteDate(row["completed_at"])
        let lastAttemptAt = parseSQLiteDate(row["last_attempt_at"])

        return AIGenerationJob(
            id: id,
            type: type,
            status: status,
            modelId: modelId,
            trackId: trackId,
            transcriptId: transcriptId,
            sourceContext: sourceContext,
            displayName: displayName,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            payloadJSON: payloadJSON,
            metadataJSON: metadataJSON,
            streamedOutput: streamedOutput,
            finalOutput: finalOutput,
            usageJSON: usageJSON,
            progress: progress,
            errorMessage: errorMessage,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
            completedAt: completedAt,
            retryCount: retryCount,
            lastAttemptAt: lastAttemptAt
        )
    }

    private func parseSQLiteDate(_ raw: Any?) -> Date? {
        if let date = raw as? Date {
            return date
        }
        if let string = raw as? String {
            return Self.sqliteDateFormatter.date(from: string)
        }
        return nil
    }
}
