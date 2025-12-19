import Foundation
import GRDB

extension GRDBDatabaseManager {
    // MARK: - Transcript Segment Updates
    
    /// Load all transcript segments for a transcript, sorted by start time
    func loadSortedTranscriptSegments(transcriptId: String) async throws -> [TranscriptSegment] {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM transcript_segments
                    WHERE transcript_id = ?
                    ORDER BY start_time_ms ASC
                """,
                arguments: [transcriptId]
            )
            
            return rows.compactMap { row in
                guard
                    let id = row["id"] as? String,
                    let transcriptId = row["transcript_id"] as? String,
                    let text = row["text"] as? String
                else {
                    return nil
                }
                
                let startTimeMs: Int = row["start_time_ms"]
                let endTimeMs: Int = row["end_time_ms"]
                let confidence = row["confidence"] as? Double
                let speaker = row["speaker"] as? String
                let language = row["language"] as? String
                let lastRepairModel = row["last_repair_model"] as? String
                let lastRepairAtString = row["last_repair_at"] as? String
                let lastRepairAt: Date? = lastRepairAtString.flatMap { Self.sqliteDateFormatter.date(from: $0) }
                
                return TranscriptSegment(
                    id: id,
                    transcriptId: transcriptId,
                    text: text,
                    startTimeMs: startTimeMs,
                    endTimeMs: endTimeMs,
                    confidence: confidence,
                    speaker: speaker,
                    language: language,
                    lastRepairModel: lastRepairModel,
                    lastRepairAt: lastRepairAt
                )
            }
        }
    }
    
    /// Update the text of a transcript segment
    func updateTranscriptSegmentText(segmentId: String, newText: String) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE transcript_segments
                    SET text = ?
                    WHERE id = ?
                """,
                arguments: [newText, segmentId]
            )
        }
    }
    
    /// Rebuild the full_text field in the transcript record from all segments
    func rebuildTranscriptFullText(transcriptId: String) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        let segments = try await loadSortedTranscriptSegments(transcriptId: transcriptId)
        
        // Concatenate all segment texts
        let fullText = segments
            .map { $0.text }
            .joined(separator: "\n")
        
        try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE transcripts
                    SET full_text = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    fullText,
                    Self.sqliteDateFormatter.string(from: Date()),
                    transcriptId
                ]
            )
        }
    }
    
    /// Apply multiple corrections to a transcript and update their status
    func applyTranscriptCorrectionsBatch(
        trackId: String,
        corrections: [(id: String, incorrect: String, correct: String)]
    ) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        // Load transcript first to get ID
        guard let transcript = try await loadTranscript(forTrackId: trackId) else {
            throw DatabaseError.notFound("Transcript not found for track \(trackId)")
        }
        
        // Load segments (read outside write transaction)
        let segments = try await loadSortedTranscriptSegments(transcriptId: transcript.id)
        
        try await db.write { database in
            var updatedSegmentCount = 0
            
            // In-memory update of segments to calculate full text
            var currentSegments = segments
            
            // Iterate over segments
            for i in 0..<currentSegments.count {
                var text = currentSegments[i].text
                var changed = false
                
                for (_, incorrect, correct) in corrections {
                    if text.contains(incorrect) {
                        text = text.replacingOccurrences(of: incorrect, with: correct)
                        changed = true
                    }
                }
                
                if changed {
                    currentSegments[i] = TranscriptSegment(
                        id: currentSegments[i].id,
                        transcriptId: currentSegments[i].transcriptId,
                        text: text,
                        startTimeMs: currentSegments[i].startTimeMs,
                        endTimeMs: currentSegments[i].endTimeMs,
                        confidence: currentSegments[i].confidence,
                        speaker: currentSegments[i].speaker,
                        language: currentSegments[i].language,
                        lastRepairModel: currentSegments[i].lastRepairModel,
                        lastRepairAt: currentSegments[i].lastRepairAt
                    )
                    
                    // Update DB
                    try database.execute(
                        sql: "UPDATE transcript_segments SET text = ? WHERE id = ?",
                        arguments: [text, currentSegments[i].id]
                    )
                    updatedSegmentCount += 1
                }
            }
            
            // Rebuild full text if needed
            if updatedSegmentCount > 0 {
                let fullText = currentSegments.map { $0.text }.joined(separator: "\n")
                
                try database.execute(
                    sql: """
                        UPDATE transcripts
                        SET full_text = ?, updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        fullText,
                        Self.sqliteDateFormatter.string(from: Date()),
                        transcript.id
                    ]
                )
            }
            
            // Update correction statuses
            let nowStr = Self.sqliteDateFormatter.string(from: Date())
            for (id, _, _) in corrections {
                try database.execute(
                    sql: """
                        UPDATE transcript_corrections
                        SET is_applied = 1, applied_at = ?, updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [nowStr, nowStr, id]
                )
            }
        }
    }

    /// Apply text replacements without updating correction status
    func applyTextReplacements(
        trackId: String,
        replacements: [(from: String, to: String)]
    ) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        guard let transcript = try await loadTranscript(forTrackId: trackId) else {
            throw DatabaseError.notFound("Transcript not found for track \(trackId)")
        }
        
        let segments = try await loadSortedTranscriptSegments(transcriptId: transcript.id)
        
        try await db.write { database in
            var updatedSegmentCount = 0
            var currentSegments = segments
            
            for i in 0..<currentSegments.count {
                var text = currentSegments[i].text
                var changed = false
                
                for (fromText, toText) in replacements {
                    if text.contains(fromText) {
                        text = text.replacingOccurrences(of: fromText, with: toText)
                        changed = true
                    }
                }
                
                if changed {
                    currentSegments[i] = TranscriptSegment(
                        id: currentSegments[i].id,
                        transcriptId: currentSegments[i].transcriptId,
                        text: text,
                        startTimeMs: currentSegments[i].startTimeMs,
                        endTimeMs: currentSegments[i].endTimeMs,
                        confidence: currentSegments[i].confidence,
                        speaker: currentSegments[i].speaker,
                        language: currentSegments[i].language,
                        lastRepairModel: currentSegments[i].lastRepairModel,
                        lastRepairAt: currentSegments[i].lastRepairAt
                    )
                    
                    try database.execute(
                        sql: "UPDATE transcript_segments SET text = ? WHERE id = ?",
                        arguments: [text, currentSegments[i].id]
                    )
                    updatedSegmentCount += 1
                }
            }
            
            if updatedSegmentCount > 0 {
                let fullText = currentSegments.map { $0.text }.joined(separator: "\n")
                try database.execute(
                    sql: """
                        UPDATE transcripts
                        SET full_text = ?, updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        fullText,
                        Self.sqliteDateFormatter.string(from: Date()),
                        transcript.id
                    ]
                )
            }
        }
    }
}
