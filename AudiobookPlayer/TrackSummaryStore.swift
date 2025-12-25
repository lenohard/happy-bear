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

    func fetchTrackIdsWithCompletedSummaries(trackIds: [String]) throws -> Set<String> {
        guard !trackIds.isEmpty else { return [] }
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try db.read { database in
            let placeholders = trackIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT track_id FROM track_summaries
                WHERE track_id IN (
                    \(placeholders)
                )
                AND status = ?
                AND summary_body IS NOT NULL
                AND summary_body != ''
            """
            let arguments = StatementArguments(trackIds + [TrackSummary.Status.complete.rawValue])
            let rows = try Row.fetchAll(database, sql: sql, arguments: arguments)
            return Set(rows.compactMap { $0["track_id"] as? String })
        }
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
        mentionedItems: [String],
        suggestedCorrections: [String: String],
        translations: [TrackSummaryTranslation] = [],
        sections: [TrackSummarySection],
        modelIdentifier: String?,
        jobId: String?,
        translationOnly: Bool = false
    ) throws -> TrackSummary {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let existing = try fetchTrackSummary(forTrackId: trackId)

        if translationOnly, existing != nil {
            let now = Date()
            let translationSegmentsJSON = encodeTranslations(translations)

            try db.write { database in
                try database.execute(
                    sql: """
                    UPDATE track_summaries
                    SET translation_segments_json = ?,
                        last_job_id = ?,
                        model_identifier = COALESCE(?, model_identifier),
                        updated_at = ?,
                        generated_at = COALESCE(generated_at, ?)
                    WHERE track_id = ?
                    """,
                    arguments: [
                        translationSegmentsJSON,
                        jobId,
                        modelIdentifier,
                        Self.sqliteDateFormatter.string(from: now),
                        Self.sqliteDateFormatter.string(from: now),
                        trackId
                    ]
                )
            }

            return try fetchTrackSummary(forTrackId: trackId) ?? existing ?? TrackSummary(
                id: trackId,
                trackId: trackId,
                transcriptId: transcriptId,
                language: language
            )
        }

        let summaryId = existing?.id ?? trackId
        let createdAt = existing?.createdAt ?? Date()
        let now = Date()
        let keywordsJSON = encodeKeywords(keywords)
        let mentionedItemsJSON = encodeKeywords(mentionedItems)
        let suggestedCorrectionsJSON = encodeDictionary(suggestedCorrections)
        let translationSegmentsJSON = encodeTranslations(translations)

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
                    summary_title, summary_body, keywords_json, mentioned_items_json, suggested_corrections_json, translation_segments_json, section_count,
                    model_identifier, generated_at, status, error_message, last_job_id,
                    created_at, updated_at
                ) VALUES (
                    ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?, ?,
                    NULL,
                    ?, ?, ?
                )
                ON CONFLICT(track_id) DO UPDATE SET
                    transcript_id = excluded.transcript_id,
                    language = excluded.language,
                    summary_title = excluded.summary_title,
                    summary_body = excluded.summary_body,
                    keywords_json = excluded.keywords_json,
                    mentioned_items_json = excluded.mentioned_items_json,
                    suggested_corrections_json = excluded.suggested_corrections_json,
                    translation_segments_json = excluded.translation_segments_json,
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
                    mentionedItemsJSON,
                    suggestedCorrectionsJSON,
                    translationSegmentsJSON,
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
            
            // Save suggested corrections as transcript corrections (if any)
            if !suggestedCorrections.isEmpty {
                for (incorrectText, correctText) in suggestedCorrections {
                    let correctionId = UUID().uuidString
                    try database.execute(
                        sql: """
                        INSERT OR IGNORE INTO transcript_corrections
                        (id, track_id, incorrect_text, correct_text, is_applied, applied_at, created_at, updated_at)
                        VALUES (?, ?, ?, ?, 0, NULL, ?, ?)
                        """,
                        arguments: [
                            correctionId,
                            trackId,
                            incorrectText,
                            correctText,
                            Self.sqliteDateFormatter.string(from: now),
                            Self.sqliteDateFormatter.string(from: now)
                        ]
                    )
                }
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
            mentionedItems: mentionedItems,
            suggestedCorrections: suggestedCorrections,
            sectionCount: normalizedSections.count,
            translations: translations,
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
        jobId: String?,
        translationOnly: Bool = false
    ) throws {
        try initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        if translationOnly, let existing = try fetchTrackSummary(forTrackId: trackId),
           existing.summaryBody?.isEmpty == false {
            let now = Date()
            try db.write { database in
                try database.execute(
                    sql: """
                    UPDATE track_summaries
                    SET last_job_id = ?,
                        updated_at = ?
                    WHERE track_id = ?
                    """,
                    arguments: [
                        jobId,
                        Self.sqliteDateFormatter.string(from: now),
                        trackId
                    ]
                )
            }
            return
        }

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
        let mentionedItemsJSON = row["mentioned_items_json"] as? String
        let suggestedCorrectionsJSON = row["suggested_corrections_json"] as? String
        let translationSegmentsJSON = row["translation_segments_json"] as? String
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
            mentionedItems: decodeKeywords(mentionedItemsJSON),
            suggestedCorrections: decodeDictionary(suggestedCorrectionsJSON),
            sectionCount: sectionCount,
            translations: decodeTranslations(translationSegmentsJSON),
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

    private func encodeTranslations(_ translations: [TrackSummaryTranslation]) -> String? {
        guard !translations.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(translations) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeTranslations(_ json: String?) -> [TrackSummaryTranslation] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TrackSummaryTranslation].self, from: data) else {
            return []
        }
        return decoded
    }

    func addMentionedItemsColumnIfNeeded(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(track_summaries)")
        let existingColumns = Set(rows.compactMap { $0["name"] as? String })

        if !existingColumns.contains("mentioned_items_json") {
            try database.execute(sql: "ALTER TABLE track_summaries ADD COLUMN mentioned_items_json TEXT")
        }

        if !existingColumns.contains("suggested_corrections_json") {
            try database.execute(sql: "ALTER TABLE track_summaries ADD COLUMN suggested_corrections_json TEXT")
        }

        if !existingColumns.contains("translation_segments_json") {
            try database.execute(sql: "ALTER TABLE track_summaries ADD COLUMN translation_segments_json TEXT")
        }
    }

    private func encodeDictionary(_ dict: [String: String]) -> String? {
        guard !dict.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeDictionary(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
