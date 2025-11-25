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
}
