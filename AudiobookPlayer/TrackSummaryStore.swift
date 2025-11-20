import Foundation
import GRDB

extension GRDBDatabaseManager {
    // MARK: - Fetching

    func fetchTrackSummary(forTrackId trackId: String) throws -> TrackSummary? {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM track_summaries WHERE track_id = ? LIMIT 1",
                arguments: [trackId]
            ) else {
                return nil
            }

            return try reconstructTrackSummary(row: row)
        }
    }

    func fetchTrackSummarySections(summaryId: String) throws -> [TrackSummarySection] {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM track_summary_sections
                    WHERE track_summary_id = ?
                    ORDER BY order_index ASC
                """,
                arguments: [summaryId]
            )
            return try rows.compactMap { try reconstructTrackSummarySection(row: $0) }
        }
    }

    func fetchTrackSummaryBundle(forTrackId trackId: String) throws -> (TrackSummary, [TrackSummarySection])? {
        guard let summary = try fetchTrackSummary(forTrackId: trackId) else {
            return nil
        }
        let sections = try fetchTrackSummarySections(summaryId: summary.id)
        return (summary, sections)
    }

    // MARK: - Upserts & Status

    @discardableResult
    func upsertTrackSummaryState(
        trackId: String,
        transcriptId: String,
        language: String,
        status: TrackSummary.Status,
        modelIdentifier: String?,
        jobId: String?,
        errorMessage: String? = nil
    ) throws -> TrackSummary {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let existingSummary = try fetchTrackSummary(forTrackId: trackId)
        let now = Date()
        let createdAt = existingSummary?.createdAt ?? now
        let statusValue = status.rawValue

        try db.write { database in
            try database.execute(
                sql: """
                INSERT OR IGNORE INTO track_summaries (
                    id, track_id, transcript_id, language, summary_title, summary_body,
                    keywords_json, section_count, model_identifier, generated_at,
                    status, error_message, last_job_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, NULL, NULL, NULL, 0, ?, NULL, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    trackId,
                    trackId,
                    transcriptId,
                    language,
                    modelIdentifier,
                    statusValue,
                    errorMessage,
                    jobId,
                    Self.sqliteDateFormatter.string(from: createdAt),
                    Self.sqliteDateFormatter.string(from: now)
                ]
            )

            try database.execute(
                sql: """
                UPDATE track_summaries
                SET transcript_id = ?,
                    language = ?,
                    status = ?,
                    error_message = ?,
                    last_job_id = ?,
                    model_identifier = ?,
                    updated_at = ?
                WHERE track_id = ?
                """,
                arguments: [
                    transcriptId,
                    language,
                    statusValue,
                    errorMessage,
                    jobId,
                    modelIdentifier,
                    Self.sqliteDateFormatter.string(from: now),
                    trackId
                ]
            )
        }

        return try fetchTrackSummary(forTrackId: trackId) ?? TrackSummary(
            id: trackId,
            trackId: trackId,
            transcriptId: transcriptId,
            language: language,
            status: status,
            errorMessage: errorMessage,
            lastJobId: jobId,
            createdAt: createdAt,
            updatedAt: now
        )
    }

    @discardableResult
    func persistTrackSummaryResult(
        trackId: String,
        transcriptId: String,
        language: String,
        summaryTitle: String?,
        summaryBody: String?,
        keywords: [String],
        sections: [TrackSummarySection],
        modelIdentifier: String?,
        jobId: String?
    ) throws -> TrackSummary {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let existing = try fetchTrackSummary(forTrackId: trackId)
        let summaryId = existing?.id ?? trackId
        let createdAt = existing?.createdAt ?? Date()
        let now = Date()
        let keywordsJSON = encodeKeywords(keywords)

        // Ensure sections reference correct summary ID and remain ordered
        let normalizedSections = sections
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { section -> TrackSummarySection in
                TrackSummarySection(
                    id: section.id,
                    trackSummaryId: summaryId,
                    orderIndex: section.orderIndex,
                    startTimeMs: section.startTimeMs,
                    endTimeMs: section.endTimeMs,
                    title: section.title,
                    summary: section.summary,
                    keywords: section.keywords,
                    createdAt: section.createdAt,
                    updatedAt: now
                )
            }

        try db.write { database in
            try database.execute(
                sql: """
                INSERT INTO track_summaries (
                    id, track_id, transcript_id, language,
                    summary_title, summary_body, keywords_json, section_count,
                    model_identifier, generated_at, status, error_message, last_job_id,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET
                    transcript_id = excluded.transcript_id,
                    language = excluded.language,
                    summary_title = excluded.summary_title,
                    summary_body = excluded.summary_body,
                    keywords_json = excluded.keywords_json,
                    section_count = excluded.section_count,
                    model_identifier = excluded.model_identifier,
                    generated_at = excluded.generated_at,
                    status = excluded.status,
                    error_message = NULL,
                    last_job_id = excluded.last_job_id,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    summaryId,
                    trackId,
                    transcriptId,
                    language,
                    summaryTitle,
                    summaryBody,
                    keywordsJSON,
                    normalizedSections.count,
                    modelIdentifier,
                    Self.sqliteDateFormatter.string(from: now),
                    TrackSummary.Status.complete.rawValue,
                    jobId,
                    Self.sqliteDateFormatter.string(from: createdAt),
                    Self.sqliteDateFormatter.string(from: now)
                ]
            )

            try database.execute(
                sql: "DELETE FROM track_summary_sections WHERE track_summary_id = ?",
                arguments: [summaryId]
            )

            for section in normalizedSections {
                try database.execute(
                    sql: """
                    INSERT INTO track_summary_sections (
                        id, track_summary_id, order_index, start_time_ms, end_time_ms,
                        title, summary, keywords_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        section.id,
                        summaryId,
                        section.orderIndex,
                        section.startTimeMs,
                        section.endTimeMs,
                        section.title,
                        section.summary,
                        encodeKeywords(section.keywords),
                        Self.sqliteDateFormatter.string(from: section.createdAt),
                        Self.sqliteDateFormatter.string(from: section.updatedAt)
                    ]
                )
            }
        }

        return TrackSummary(
            id: summaryId,
            trackId: trackId,
            transcriptId: transcriptId,
            language: language,
            summaryTitle: summaryTitle,
            summaryBody: summaryBody,
            keywords: keywords,
            sectionCount: normalizedSections.count,
            modelIdentifier: modelIdentifier,
            generatedAt: now,
            status: .complete,
            errorMessage: nil,
            lastJobId: jobId,
            createdAt: createdAt,
            updatedAt: now
        )
    }

    func markTrackSummaryFailed(
        trackId: String,
        transcriptId: String,
        language: String,
        message: String,
        jobId: String?
    ) throws {
        try _ = upsertTrackSummaryState(
            trackId: trackId,
            transcriptId: transcriptId,
            language: language,
            status: .failed,
            modelIdentifier: nil,
            jobId: jobId,
            errorMessage: message
        )
    }

    func deleteTrackSummary(forTrackId trackId: String) throws {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        try db.write { database in
            if let summaryRow = try Row.fetchOne(
                database,
                sql: "SELECT id FROM track_summaries WHERE track_id = ?",
                arguments: [trackId]
            ), let summaryId = summaryRow["id"] as? String {
                try database.execute(
                    sql: "DELETE FROM track_summary_sections WHERE track_summary_id = ?",
                    arguments: [summaryId]
                )
                try database.execute(
                    sql: "DELETE FROM track_summaries WHERE id = ?",
                    arguments: [summaryId]
                )
            }
        }
    }

    // MARK: - Helpers

    private func reconstructTrackSummary(row: Row) throws -> TrackSummary? {
        guard
            let id = row["id"] as? String,
            let trackId = row["track_id"] as? String,
            let transcriptId = row["transcript_id"] as? String
        else {
            return nil
        }

        let language = row["language"] as? String ?? "en"
        let summaryTitle = row["summary_title"] as? String
        let summaryBody = row["summary_body"] as? String
        let keywordsJSON = row["keywords_json"] as? String
        let sectionCount = (row["section_count"] as? Int) ?? 0
        let model = row["model_identifier"] as? String
        let statusRaw = row["status"] as? String ?? TrackSummary.Status.idle.rawValue
        let errorMessage = row["error_message"] as? String
        let lastJobId = row["last_job_id"] as? String

        let createdAt = parseSQLiteDate(row["created_at"]) ?? Date()
        let updatedAt = parseSQLiteDate(row["updated_at"]) ?? createdAt
        let generatedAt = parseSQLiteDate(row["generated_at"])

        return TrackSummary(
            id: id,
            trackId: trackId,
            transcriptId: transcriptId,
            language: language,
            summaryTitle: summaryTitle,
            summaryBody: summaryBody,
            keywords: decodeKeywords(keywordsJSON),
            sectionCount: sectionCount,
            modelIdentifier: model,
            generatedAt: generatedAt,
            status: TrackSummary.Status(rawValue: statusRaw) ?? .idle,
            errorMessage: errorMessage,
            lastJobId: lastJobId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func reconstructTrackSummarySection(row: Row) throws -> TrackSummarySection? {
        guard
            let id = row["id"] as? String,
            let summaryId = row["track_summary_id"] as? String,
            let summaryText = row["summary"] as? String
        else {
            return nil
        }

        let orderIndex = (row["order_index"] as? Int) ?? 0
        let startTimeMs: Int = row["start_time_ms"]
        let endTimeMs = row["end_time_ms"] as? Int
        let title = row["title"] as? String
        let keywordsJSON = row["keywords_json"] as? String
        let createdAt = parseSQLiteDate(row["created_at"]) ?? Date()
        let updatedAt = parseSQLiteDate(row["updated_at"]) ?? createdAt

        return TrackSummarySection(
            id: id,
            trackSummaryId: summaryId,
            orderIndex: orderIndex,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            title: title,
            summary: summaryText,
            keywords: decodeKeywords(keywordsJSON),
            createdAt: createdAt,
            updatedAt: updatedAt
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

    private func encodeKeywords(_ keywords: [String]) -> String? {
        guard !keywords.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(keywords) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeKeywords(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}
