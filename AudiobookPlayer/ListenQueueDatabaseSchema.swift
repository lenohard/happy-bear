import Foundation
import GRDB

/// Database schema for the Listen Queue feature (see `local/task/listen-queue.md`).
///
/// The schema is additive:
/// - `queue_lists` holds named lists. In v1 only the single "default" list is used,
///   but the table is modeled for future multi-playlist support.
/// - `queue_items` holds individual queue entries. Each item references either a
///   track (`target_kind='track'`) or a whole collection (`target_kind='collection'`).
///
/// The schema uses `ON DELETE CASCADE` so rows disappear automatically when their
/// underlying track or collection is removed.
enum ListenQueueDatabaseSchema {
    /// Deterministic id used for the built-in default queue list.
    /// Stable value so multiple launches never create duplicates.
    static let defaultListID: String = "00000000-0000-0000-0000-000000000001"

    /// SQL for creating the listen-queue tables.
    /// Executed inside `GRDBDatabaseManager.initializeDatabase()` alongside the other schemas.
    static let createTableSQL = """
    -- Lists (forward-compatible with multi-playlist UI)
    CREATE TABLE IF NOT EXISTS queue_lists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
    );

    -- Queue items
    CREATE TABLE IF NOT EXISTS queue_items (
        id TEXT PRIMARY KEY,
        list_id TEXT NOT NULL,
        target_kind TEXT NOT NULL CHECK (target_kind IN ('track','collection')),
        collection_id TEXT NOT NULL,
        track_id TEXT,
        position REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        added_at DATETIME NOT NULL,
        completed_at DATETIME,
        note TEXT,
        FOREIGN KEY (list_id) REFERENCES queue_lists(id) ON DELETE CASCADE,
        FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_queue_items_list_status_position
        ON queue_items(list_id, status, position);
    CREATE INDEX IF NOT EXISTS idx_queue_items_track ON queue_items(track_id);
    CREATE INDEX IF NOT EXISTS idx_queue_items_collection ON queue_items(collection_id);

    -- Prevent duplicate *pending* entries for the same track/collection in a given list.
    -- Completed rows are allowed to co-exist with a new pending row (re-queue after finishing).
    CREATE UNIQUE INDEX IF NOT EXISTS uq_queue_pending_track
        ON queue_items(list_id, track_id)
        WHERE status='pending' AND track_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS uq_queue_pending_collection
        ON queue_items(list_id, collection_id)
        WHERE status='pending' AND target_kind='collection';
    """

    /// SQL to seed the default list row on first run. Safe to run repeatedly (INSERT OR IGNORE).
    static func seedDefaultListSQL(now: Date) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        let sql = """
        INSERT OR IGNORE INTO queue_lists (id, name, is_default, created_at, updated_at)
        VALUES (?, ?, 1, ?, ?)
        """
        return (sql, [defaultListID, "Default", now, now])
    }
}
