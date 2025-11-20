# Structured Storage Migration

## Summary
- **Current State**: Library persistence is a single JSON file written wholesale on every change.
- **Objective**: Migrate to a structured, incremental store that scales to hundreds of collections and thousands of tracks.
- **Approach**: Adopt an embedded SQLite database using [GRDB](https://github.com/groue/GRDB.swift) for type-safe queries, efficient batch operations, and straightforward background saves.

## Rationale for GRDB/SQLite
- Proven performance on Apple platforms, including large data sets.
- Offers simple Codable integration so we can reuse existing model structs during the migration.
- Fine-grained transactions make it easy to update a single track/collection without rewriting the whole dataset.
- Compatible with background tasks and future sync (optional CloudKit mirror can still run via custom logic).
- Avoids OS version constraints (unlike SwiftData) and is less heavyweight than refitting the app around Core Data’s managed object graph.

## Migration Goals
1. **Schema Design**: Normalize collections, tracks, playback states, favorites, and tags into tables with foreign keys.
2. **Incremental Persistence**: Replace `LibraryPersistence` JSON methods with GRDB-backed CRUD.
3. **Compatibility Layer**: Provide JSON import/export for existing users and backups.
4. **Performance Validation**: Benchmarks for 100 collections × 1 000 tracks (load < 200 ms, save < 50 ms per change).
5. **Testing**: Add integration tests covering migrations, inserts, updates, deletes, and rollback on failure.

## Proposed Schema (Draft)
| Table | Key Columns | Notes |
|-------|-------------|-------|
| `collections` | `id (UUID PK)`, `title`, `author`, `description`, `cover_kind`, `cover_data`, `created_at`, `updated_at`, `source_type`, `source_payload` | `source_payload` stores JSON blob for Baidu/local/external specifics. |
| `tracks` | `id (UUID PK)`, `collection_id (FK)`, `display_name`, `filename`, `location_type`, `location_payload`, `file_size`, `duration`, `track_number`, `checksum`, `metadata_json` | Index on `(collection_id, track_number)` for ordering. |
| `playback_states` | `track_id (PK)`, `collection_id (FK)`, `position`, `duration`, `updated_at` | Single row per track; join via `track_id`. |
| `favorites` | `track_id (PK)`, `collection_id (FK)`, `favorited_at` | Keeps favorite info separate so defaults don’t bloat main track rows. |
| `tags` | `collection_id (FK)`, `tag` | Composite PK `(collection_id, tag)` to avoid duplicates. |
| `schema_state` | `version` | Tracks migrations (starting at 1). |

All payload columns use `TEXT` storing JSON so we can reuse existing Codable encode/ decode for complex enums.

## Work Plan (High Level)
1. **Set Up Package**: Add GRDB via SwiftPM, configure database path in `Application Support/AudiobookPlayer/library.sqlite`.
2. **Schema Migration 1**: Create tables above with GRDB migrator, seed `schema_state`.
3. **Data Access Layer**: Implement DAO structs (CollectionsDAO, TracksDAO, etc.) plus helpers to map between DB rows and existing model structs.
4. **Migration Command**: Read existing JSON (`LibraryPersistence`) and import into SQLite within a transaction; mark JSON as archived.
5. **Replace Persistence**: Swap `LibraryPersistence.load/save` to use GRDB; keep JSON fallback for export only.
6. **Testing & Benchmarks**: Add XCTest coverage, run sample dataset to measure load/save durations.
7. **Cleanup**: Remove unused JSON code paths once migration is stable; update documentation.

## Migration Strategy (Protect Existing Data)
- Detect legacy JSON on launch; if missing, assume fresh install.
- Before importing, copy the JSON snapshot to `library.json.backup` so users can restore manually if migration fails.
- Run import inside a single SQLite transaction. On any error, roll back, surface the failure, and continue using legacy JSON so data isn’t lost.
- After successful import, mark the new schema version in `schema_state` and keep the backup JSON until the user has run the app successfully (optional cleanup prompt later).
- Provide manual export/import commands so advanced users can re-import the backup if needed.
- Keep JSON export utilities around so CloudKit sync or other services can still serialize collections when required.

## Open Questions / Assumptions
- Minimum deployment target supports Swift Package Manager & GRDB (iOS 14+, macOS 11+). Confirm with user if lower support is required.
- Cloud sync strategy: keep current CloudKit-based sync engine but move serialization to GRDB snapshots per collection?
- Need background migration path to move existing JSON data into SQLite on first launch; plan to run once and archive old JSON.

## Next Steps
1. Draft schema sketches and migration path.
2. Integrate GRDB via Swift Package Manager.
3. Implement new `LibraryPersistence` backed by GRDB with unit tests.
4. Build migration command to import current JSON snapshot.
5. Wire UI/Store to new persistence and validate performance.

## Session Notes
- Created as part of performance optimization initiative (2025-11-05).
- Linked from `local/PROD.md` under “Opt: Structured Storage Migration”.
