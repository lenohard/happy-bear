import Foundation
import GRDB

extension GRDBDatabaseManager {
    // MARK: - Defaults

    func fetchTrackChatDefaults(trackId: String) async throws -> TrackChatContextSelection? {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try await db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT context_flags FROM track_chat_defaults WHERE track_id = ?",
                arguments: [trackId]
            ) else {
                return nil
            }
            let contextJSON: String? = row["context_flags"]
            return self.decodeContextSelection(contextJSON)
        }
    }

    func saveTrackChatDefaults(trackId: String, selection: TrackChatContextSelection) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let now = Date()
        let contextJSON = encodeContextSelection(selection)

        try await db.write { database in
            try database.execute(
                sql: """
                INSERT INTO track_chat_defaults (track_id, context_flags, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET
                    context_flags = excluded.context_flags,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    trackId,
                    contextJSON,
                    Self.sqliteDateFormatter.string(from: now)
                ]
            )
        }
    }

    // MARK: - Sessions

    func fetchTrackChatSessions(trackId: String) async throws -> [TrackChatSession] {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM track_chat_sessions
                    WHERE track_id = ?
                    ORDER BY updated_at DESC
                """,
                arguments: [trackId]
            )
            return try rows.compactMap { try self.reconstructTrackChatSession(row: $0) }
        }
    }

    func fetchMostRecentTrackChatSession(trackId: String) async throws -> TrackChatSession? {
        try await fetchTrackChatSessions(trackId: trackId).first
    }

    func createTrackChatSession(
        trackId: String,
        collectionId: String?,
        modelId: String?,
        title: String?,
        contextSelection: TrackChatContextSelection,
        contextSnapshot: String?
    ) async throws -> TrackChatSession {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let session = TrackChatSession(
            trackId: trackId,
            collectionId: collectionId,
            title: title,
            modelId: modelId,
            contextSelection: contextSelection,
            contextSnapshot: contextSnapshot
        )
        let contextJSON = encodeContextSelection(session.contextSelection)
        let now = Date()

        try await db.write { database in
            try database.execute(
                sql: """
                INSERT INTO track_chat_sessions (
                    id, track_id, collection_id, title, model_id,
                    context_flags, context_snapshot, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id,
                    session.trackId,
                    session.collectionId,
                    session.title,
                    session.modelId,
                    contextJSON,
                    session.contextSnapshot,
                    Self.sqliteDateFormatter.string(from: session.createdAt),
                    Self.sqliteDateFormatter.string(from: now)
                ]
            )
        }

        return TrackChatSession(
            id: session.id,
            trackId: session.trackId,
            collectionId: session.collectionId,
            title: session.title,
            modelId: session.modelId,
            contextSelection: session.contextSelection,
            contextSnapshot: session.contextSnapshot,
            createdAt: session.createdAt,
            updatedAt: now
        )
    }

    func updateTrackChatSession(
        sessionId: String,
        modelId: String?,
        contextSelection: TrackChatContextSelection?,
        contextSnapshot: String?
    ) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let now = Date()
        let contextJSON = contextSelection.map { encodeContextSelection($0) }

        try await db.write { database in
            try database.execute(
                sql: """
                UPDATE track_chat_sessions
                SET model_id = COALESCE(?, model_id),
                    context_flags = COALESCE(?, context_flags),
                    context_snapshot = COALESCE(?, context_snapshot),
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    modelId,
                    contextJSON,
                    contextSnapshot,
                    Self.sqliteDateFormatter.string(from: now),
                    sessionId
                ]
            )
        }
    }

    func touchTrackChatSession(sessionId: String) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let now = Date()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE track_chat_sessions SET updated_at = ? WHERE id = ?",
                arguments: [Self.sqliteDateFormatter.string(from: now), sessionId]
            )
        }
    }

    // MARK: - Messages

    func fetchTrackChatMessages(sessionId: String) async throws -> [TrackChatMessage] {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        return try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM track_chat_messages
                    WHERE session_id = ?
                    ORDER BY created_at ASC
                """,
                arguments: [sessionId]
            )
            return try rows.compactMap { try self.reconstructTrackChatMessage(row: $0) }
        }
    }

    func insertTrackChatMessage(_ message: TrackChatMessage) async throws {
        try await initializeDatabase()
        guard let db else { throw DatabaseError.initializationFailed("Database not initialized") }

        let metadataJSON = encodeMessageMetadata(message.metadata)

        try await db.write { database in
            try database.execute(
                sql: """
                INSERT INTO track_chat_messages (
                    id, session_id, role, content, metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id,
                    message.sessionId,
                    message.role.rawValue,
                    message.content,
                    metadataJSON,
                    Self.sqliteDateFormatter.string(from: message.createdAt)
                ]
            )
        }
    }

    // MARK: - Row Reconstruction (nonisolated for use in db closures)

    private nonisolated func reconstructTrackChatSession(row: Row) throws -> TrackChatSession {
        let id: String = row["id"]
        let trackId: String = row["track_id"]
        let collectionId: String? = row["collection_id"]
        let title: String? = row["title"]
        let modelId: String? = row["model_id"]
        let contextJSON: String? = row["context_flags"]
        let contextSnapshot: String? = row["context_snapshot"]
        let createdAt = parseDate(row["created_at"]) ?? Date()
        let updatedAt = parseDate(row["updated_at"]) ?? createdAt

        let contextSelection = decodeContextSelection(contextJSON) ?? TrackChatContextSelection.default(transcriptAvailable: true)

        return TrackChatSession(
            id: id,
            trackId: trackId,
            collectionId: collectionId,
            title: title,
            modelId: modelId,
            contextSelection: contextSelection,
            contextSnapshot: contextSnapshot,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private nonisolated func reconstructTrackChatMessage(row: Row) throws -> TrackChatMessage {
        let id: String = row["id"]
        let sessionId: String = row["session_id"]
        let roleString: String = row["role"]
        let content: String = row["content"]
        let createdAt = parseDate(row["created_at"]) ?? Date()
        let metadataJSON: String? = row["metadata_json"]
        let metadata = decodeMessageMetadata(metadataJSON)

        let role = TrackChatMessageRole(rawValue: roleString) ?? .assistant

        return TrackChatMessage(
            id: id,
            sessionId: sessionId,
            role: role,
            content: content,
            metadata: metadata,
            createdAt: createdAt
        )
    }

    private nonisolated func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return Self.sqliteDateFormatter.date(from: value)
    }

    private nonisolated func encodeContextSelection(_ selection: TrackChatContextSelection) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(selection) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated func decodeContextSelection(_ json: String?) -> TrackChatContextSelection? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(TrackChatContextSelection.self, from: data)
    }

    private nonisolated func encodeMessageMetadata(_ metadata: TrackChatMessageMetadata?) -> String? {
        guard let metadata else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated func decodeMessageMetadata(_ json: String?) -> TrackChatMessageMetadata? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(TrackChatMessageMetadata.self, from: data)
    }
}
