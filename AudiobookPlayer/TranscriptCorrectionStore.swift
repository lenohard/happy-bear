import Foundation
import GRDB

extension GRDBDatabaseManager {
    // MARK: - Transcript Corrections
    
    /// Load all corrections for a track
    func loadTranscriptCorrections(trackId: String) async throws -> [TranscriptCorrection] {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        return try await db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, track_id, incorrect_text, correct_text, is_applied, applied_at, created_at, updated_at
                    FROM transcript_corrections
                    WHERE track_id = ?
                    ORDER BY created_at ASC
                """,
                arguments: [trackId]
            )
            
            var corrections: [TranscriptCorrection] = []
            
            for row in rows {
                let id = row["id"] as! String
                let trackId = row["track_id"] as! String
                let incorrectText = row["incorrect_text"] as! String
                let correctText = row["correct_text"] as! String
                let isApplied = (row["is_applied"] as! Int64) != 0
                let appliedAtString = row["applied_at"] as? String
                let createdAtString = row["created_at"] as! String
                let updatedAtString = row["updated_at"] as! String
                
                let appliedAt: Date? = if let appliedAtString {
                    Self.sqliteDateFormatter.date(from: appliedAtString)
                } else {
                    nil
                }
                
                let correction = TranscriptCorrection(
                    id: id,
                    trackId: trackId,
                    incorrectText: incorrectText,
                    correctText: correctText,
                    isApplied: isApplied,
                    appliedAt: appliedAt,
                    createdAt: Self.sqliteDateFormatter.date(from: createdAtString) ?? Date(),
                    updatedAt: Self.sqliteDateFormatter.date(from: updatedAtString) ?? Date()
                )
                corrections.append(correction)
            }
            
            return corrections
        }
    }
    
    /// Add a custom correction
    func addTranscriptCorrection(trackId: String, incorrectText: String, correctText: String) async throws -> TranscriptCorrection {
        let correction = TranscriptCorrection(
            trackId: trackId,
            incorrectText: incorrectText.trimmingCharacters(in: .whitespacesAndNewlines),
            correctText: correctText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { db in
            let row = TranscriptCorrectionRow(from: correction)
            
            try db.execute(
                sql: """
                    INSERT INTO transcript_corrections 
                    (id, track_id, incorrect_text, correct_text, is_applied, applied_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.id,
                    row.trackId,
                    row.incorrectText,
                    row.correctText,
                    row.isApplied ? 1 : 0,
                    row.appliedAt.map { Self.sqliteDateFormatter.string(from: $0) },
                    Self.sqliteDateFormatter.string(from: row.createdAt),
                    Self.sqliteDateFormatter.string(from: row.updatedAt)
                ]
            )
        }
        
        return correction
    }
    
    /// Update correction applied status
    func updateTranscriptCorrectionStatus(id: String, isApplied: Bool) async throws {
        let now = Date()
        
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { db in
            try db.execute(
                sql: """
                    UPDATE transcript_corrections
                    SET is_applied = ?, applied_at = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    isApplied ? 1 : 0,
                    isApplied ? Self.sqliteDateFormatter.string(from: now) : nil,
                    Self.sqliteDateFormatter.string(from: now),
                    id
                ]
            )
        }
    }
    
    /// Delete a correction
    func deleteTranscriptCorrection(id: String) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }
        
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_corrections WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
