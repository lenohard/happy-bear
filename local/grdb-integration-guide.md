# GRDB Integration & Structured Storage Migration Guide

## Overview
This guide walks through adding GRDB (SQLite) support to replace single-file JSON persistence with incremental, efficient database storage.

## Current Status (2025-11-06)
- ✅ Placeholder infrastructure created
  - `DatabaseConfig.swift`: Database path and directory management
  - `DatabaseSchema.swift`: SQL schema definitions and DTOs
  - `DatabaseManager.swift`: Actor-based database operations (stub implementation)
  - `MigrationCoordinator.swift`: JSON→SQLite migration logic (stub)
- ✅ Project builds successfully with these new files
- ⏳ **Pending**: Add GRDB dependency via Xcode

## Phase 1: Adding GRDB Dependency

### Step 1: Add GRDB via Xcode UI
1. Open `AudiobookPlayer.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the **AudiobookPlayer** target
4. Go to **Build Phases** tab
5. Expand **Link Binary With Libraries**
6. Click the **+** button
7. Search for **GRDB** in the package selector
8. If not listed, add via **File > Add Packages...**:
   - Repository URL: `https://github.com/groue/GRDB.swift.git`
   - Version: `6.27.0` (or latest stable)
   - Add to project: **AudiobookPlayer**

### Step 2: Verify GRDB Installation
```bash
xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -i "grdb\|error"
```

If successful, you'll see GRDB frameworks linked in the build output.

## Phase 2: Implement GRDB Database Manager

### File: `AudiobookPlayer/GRDBDatabaseManager.swift`
This will replace the stub `DatabaseManager.swift` with actual GRDB operations.

**Key responsibilities:**
1. Initialize `DatabaseQueue` to SQLite file
2. Run migrations (create tables, indexes)
3. Implement CRUD operations for collections, tracks, playback states
4. Handle transactions for atomic updates
5. Convert between SwiftUI models ↔ database rows

**Implementation structure:**
```swift
import GRDB

actor GRDBDatabaseManager {
    static let shared = GRDBDatabaseManager()

    private let db: DatabaseQueue

    init(dbURL: URL = DatabaseConfig.defaultURL) throws {
        self.db = try DatabaseQueue(path: dbURL.path)
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try db.write { db in
            // Create tables using raw SQL from DatabaseSchema.createTableSQL
            try db.execute(DatabaseSchema.createTableSQL)

            // Insert schema version if not exists
            try db.execute("""
                INSERT OR IGNORE INTO schema_state (version) VALUES (1)
            """)
        }
    }

    // MARK: - Collection Operations

    func saveCollection(_ collection: AudiobookCollection) throws {
        try db.write { db in
            // 1. Insert/update collection record
            // 2. Delete old tracks and insert new ones
            // 3. Update playback states
            // 4. Update tags
            // 5. All within single transaction
        }
    }

    // ... other CRUD methods
}
```

### File: `AudiobookPlayer/Codable+GRDB.swift`
Add Codable extensions for database row encoding/decoding:

```swift
extension AudiobookCollection {
    /// Convert to database rows for saving
    func toCollectionRow() -> CollectionRow { ... }

    /// Reconstruct from database rows
    static func from(row: CollectionRow, tracks: [AudiobookTrack],
                     playbackStates: [UUID: TrackPlaybackState],
                     tags: [String]) -> AudiobookCollection { ... }
}

extension AudiobookTrack {
    func toTrackRow(collectionId: UUID) -> TrackRow { ... }
    static func from(row: TrackRow) -> AudiobookTrack { ... }
}

extension TrackPlaybackState {
    func toPlaybackStateRow(trackId: UUID, collectionId: UUID) -> PlaybackStateRow { ... }
    static func from(row: PlaybackStateRow) -> TrackPlaybackState { ... }
}
```

## Phase 3: JSON-to-SQLite Migration

### File: `AudiobookPlayer/MigrationService.swift`
Enhanced migration coordinator with actual GRDB operations:

```swift
actor MigrationService {
    /// Perform one-time migration from JSON to SQLite
    static func migrate() async throws {
        guard MigrationCoordinator.needsMigration() else { return }

        print("🔄 Starting JSON→SQLite migration...")

        // 1. Load existing JSON
        let jsonFile = try await LibraryPersistence.default.load()

        // 2. Create backup
        try await MigrationCoordinator.migrate(
            from: LibraryPersistence.default
        )

        // 3. Insert into SQLite
        let dbManager = try GRDBDatabaseManager.shared
        for collection in jsonFile.collections {
            try await dbManager.saveCollection(collection)
        }

        print("✅ Migration completed successfully")
    }
}
```

## Phase 4: Update LibraryStore

### Integration Points in `LibraryStore.swift`

```swift
@MainActor
final class LibraryStore: ObservableObject {
    private let persistence: GRDBDatabaseManager  // Replace LibraryPersistence

    func load() async {
        do {
            // Attempt migration from JSON on first launch
            if MigrationCoordinator.needsMigration() {
                try await MigrationService.migrate()
            }

            // Load from SQLite
            collections = try await persistence.loadAllCollections()
        } catch {
            lastError = error
        }
    }

    func save(_ collection: AudiobookCollection) {
        // Collections will be saved incrementally
        // Only the changed collection, not the entire library
        Task(priority: .utility) {
            try await persistence.saveCollection(collection)
        }
    }

    // ... other operations use GRDBDatabaseManager methods
}
```

## Phase 5: Testing & Validation

### Unit Tests
Create `AudiobookPlayerTests/GRDBDatabaseManagerTests.swift`:

```swift
import XCTest
@testable import AudiobookPlayer

class GRDBDatabaseManagerTests: XCTestCase {
    var manager: GRDBDatabaseManager!
    var testDBURL: URL!

    override func setUpWithError() throws {
        testDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_library.sqlite")
        manager = try GRDBDatabaseManager(dbURL: testDBURL)
    }

    func testSaveAndLoadCollection() async throws {
        let collection = AudiobookCollection.makeEmptyDraft(
            for: .external(description: "Test"),
            title: "Test Collection"
        )

        try await manager.saveCollection(collection)
        let loaded = try await manager.loadCollection(id: collection.id)

        XCTAssertEqual(loaded?.title, "Test Collection")
    }

    // Performance benchmark test
    func testPerformanceLarge() async throws {
        // Create 100 collections × 10 tracks each
        // Measure load/save times
        // Verify < 200ms for load, < 50ms per save
    }
}
```

### Performance Benchmarks
Expected performance targets:
- **Load all collections** (100 collections × 1,000 tracks): < 200 ms
- **Save single track** playback position: < 50 ms
- **Add batch of tracks** (50 tracks): < 100 ms
- **Delete collection**: < 30 ms

## Phase 6: Rollout & Cleanup

### Gradual Rollout
1. **v1.0**: GRDB alongside JSON (dual-write for safety)
2. **v1.1**: Deprecate JSON after stable period
3. **v1.2**: Remove JSON path entirely

### Cleanup Tasks
- [ ] Remove `LibraryPersistence` class (keep JSON export utilities)
- [ ] Remove `LibraryFile` struct if no longer needed
- [ ] Update documentation
- [ ] Remove JSON backup after 3+ successful app launches
- [ ] Add analytics to track migration success rate

## Rollback Plan
If issues arise:
1. Database detects corruption → restore from `library.json.backup`
2. User can manually restore from backup via Settings
3. Fall back to JSON persistence temporarily
4. Log detailed error for debugging

## Migration Timeline

| Phase | Task | Est. Time | Status |
|-------|------|-----------|--------|
| 1 | Add GRDB dependency | 1 hour | 🔄 In Progress |
| 2 | Implement GRDBDatabaseManager | 3 hours | Pending |
| 3 | JSON→SQLite migration service | 2 hours | Pending |
| 4 | Integrate with LibraryStore | 1 hour | Pending |
| 5 | Unit tests & benchmarks | 2 hours | Pending |
| 6 | Validation & rollout | 1 hour | Pending |
| **Total** | | **10 hours** | |

## References
- [GRDB.swift Documentation](https://github.com/groue/GRDB.swift)
- [GRDB Migrations Guide](https://github.com/groue/GRDB.swift/blob/master/README.md#database-changes)
- [DatabaseQueue API](https://github.com/groue/GRDB.swift/blob/master/README.md#databasequeue)

## Next Steps
1. ✅ Create placeholder infrastructure
2. ⏳ Add GRDB via Xcode (user action)
3. → Implement GRDBDatabaseManager with real GRDB operations
4. → Create migration service
5. → Integrate with LibraryStore
6. → Add tests and validate performance
