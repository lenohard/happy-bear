import Foundation
import GRDB

// MARK: - Listen Queue CRUD

extension GRDBDatabaseManager {
    /// Ensure the built-in default list row exists. Idempotent.
    func ensureDefaultQueueListExists() throws {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        try db.write { db in
            let (sql, args) = ListenQueueDatabaseSchema.seedDefaultListSQL(now: Date())
            try db.execute(sql: sql, arguments: StatementArguments(args) ?? StatementArguments())
        }
    }

    /// Fetch queue items filtered by status. Ordered by `position` ascending (pending playback order)
    /// or by `completed_at` descending for completed history.
    func fetchQueueItems(
        listID: String = ListenQueueDatabaseSchema.defaultListID,
        status: ListenQueueItem.Status,
        limit: Int? = nil
    ) throws -> [ListenQueueItem] {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }

        return try db.read { db in
            let orderClause: String = (status == .completed)
                ? "ORDER BY completed_at DESC, added_at DESC"
                : "ORDER BY position ASC, added_at ASC"
            let limitClause = limit.map { " LIMIT \($0)" } ?? ""

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, list_id, target_kind, collection_id, track_id,
                       position, status, added_at, completed_at, note
                FROM queue_items
                WHERE list_id = ? AND status = ?
                \(orderClause)\(limitClause)
                """,
                arguments: [listID, status.rawValue]
            )

            return rows.compactMap { Self.reconstructQueueItem(row: $0) }
        }
    }

    /// Returns the maximum `position` value among pending items in the list (for append-to-end).
    func maxPendingQueuePosition(listID: String = ListenQueueDatabaseSchema.defaultListID) throws -> Double? {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }

        return try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT MAX(position) AS max_pos FROM queue_items WHERE list_id = ? AND status = 'pending'",
                arguments: [listID]
            )
            return row?["max_pos"] as? Double
        }
    }

    /// Insert a queue item. Uses `INSERT OR IGNORE` so the partial unique index on
    /// pending track/collection is respected (duplicate pending adds are silently dropped).
    /// Returns `true` if the row was actually inserted.
    @discardableResult
    func insertQueueItem(_ item: ListenQueueItem) throws -> Bool {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        return try db.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO queue_items
                    (id, list_id, target_kind, collection_id, track_id,
                     position, status, added_at, completed_at, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id.uuidString,
                    item.listID.uuidString,
                    item.target.kindRaw,
                    item.target.collectionID.uuidString,
                    item.target.trackID?.uuidString,
                    item.position,
                    item.status.rawValue,
                    item.addedAt,
                    item.completedAt,
                    item.note
                ]
            )
            return db.changesCount > 0
        }
    }

    /// Update mutable fields on an existing queue item (position, status, completed_at, note).
    func updateQueueItem(_ item: ListenQueueItem) throws {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        try db.write { db in
            try db.execute(
                sql: """
                UPDATE queue_items
                SET position = ?, status = ?, completed_at = ?, note = ?
                WHERE id = ?
                """,
                arguments: [
                    item.position,
                    item.status.rawValue,
                    item.completedAt,
                    item.note,
                    item.id.uuidString
                ]
            )
        }
    }

    /// Delete a queue item by id.
    func deleteQueueItem(id: UUID) throws {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM queue_items WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// Delete all completed items older than the given cutoff (or all, if cutoff is nil).
    func deleteCompletedQueueItems(
        listID: String = ListenQueueDatabaseSchema.defaultListID,
        olderThan cutoff: Date?
    ) throws {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        try db.write { db in
            if let cutoff {
                try db.execute(
                    sql: """
                    DELETE FROM queue_items
                    WHERE list_id = ? AND status = 'completed' AND completed_at < ?
                    """,
                    arguments: [listID, cutoff]
                )
            } else {
                try db.execute(
                    sql: """
                    DELETE FROM queue_items
                    WHERE list_id = ? AND status = 'completed'
                    """,
                    arguments: [listID]
                )
            }
        }
    }

    /// Find pending queue item IDs referencing a given track. Used by the auto-complete hook.
    func pendingQueueItemForTrack(
        trackID: UUID,
        listID: String = ListenQueueDatabaseSchema.defaultListID
    ) throws -> ListenQueueItem? {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        return try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, list_id, target_kind, collection_id, track_id,
                       position, status, added_at, completed_at, note
                FROM queue_items
                WHERE list_id = ? AND status = 'pending' AND track_id = ?
                LIMIT 1
                """,
                arguments: [listID, trackID.uuidString]
            )
            guard let row else { return nil }
            return Self.reconstructQueueItem(row: row)
        }
    }

    /// Find pending collection-target queue items for a given collection.
    func pendingQueueItemForCollection(
        collectionID: UUID,
        listID: String = ListenQueueDatabaseSchema.defaultListID
    ) throws -> ListenQueueItem? {
        guard let db = db else {
            throw DatabaseError.initializationFailed("Database not initialized")
        }
        return try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, list_id, target_kind, collection_id, track_id,
                       position, status, added_at, completed_at, note
                FROM queue_items
                WHERE list_id = ? AND status = 'pending'
                      AND target_kind = 'collection' AND collection_id = ?
                LIMIT 1
                """,
                arguments: [listID, collectionID.uuidString]
            )
            guard let row else { return nil }
            return Self.reconstructQueueItem(row: row)
        }
    }

    // MARK: - Row reconstruction

    private static func reconstructQueueItem(row: Row) -> ListenQueueItem? {
        guard let idString = row["id"] as? String,
              let id = UUID(uuidString: idString),
              let listIDString = row["list_id"] as? String,
              let listID = UUID(uuidString: listIDString),
              let kind = row["target_kind"] as? String,
              let collectionIDString = row["collection_id"] as? String,
              let collectionID = UUID(uuidString: collectionIDString),
              let position = row["position"] as? Double,
              let statusRaw = row["status"] as? String,
              let status = ListenQueueItem.Status(rawValue: statusRaw)
        else {
            return nil
        }

        let target: ListenQueueItem.Target
        switch kind {
        case "track":
            guard let trackIDString = row["track_id"] as? String,
                  let trackID = UUID(uuidString: trackIDString)
            else { return nil }
            target = .track(collectionID: collectionID, trackID: trackID)
        case "collection":
            target = .collection(collectionID: collectionID)
        default:
            return nil
        }

        let addedAt = (row["added_at"] as? Date) ?? parseSQLiteDate(row["added_at"] as? String) ?? Date()
        let completedAt: Date? = (row["completed_at"] as? Date) ?? parseSQLiteDate(row["completed_at"] as? String)
        let note = row["note"] as? String

        return ListenQueueItem(
            id: id,
            listID: listID,
            target: target,
            position: position,
            status: status,
            addedAt: addedAt,
            completedAt: completedAt,
            note: note
        )
    }

    private static func parseSQLiteDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return GRDBDatabaseManager.sqliteDateFormatter.date(from: value)
    }
}
