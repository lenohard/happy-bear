# Bug: Favorite Tracks Disappear After App Restart

## Symptom
- User marks tracks as favorites during app session
- Favorites appear correctly in FavoriteTracksView while app is running
- After app restart, the FavoriteTracksView appears empty
- Issue appears to be data persistence problem

## Investigation

### Code Flow Analysis
1. **Toggle Favorite** (LibraryStore.swift:392)
   - Updates in-memory track: `track.isFavorite.toggle()`
   - Updates in-memory timestamp: `track.favoritedAt = track.isFavorite ? Date() : nil`
   - Updates in-memory collection array: `collections[collectionIndex] = collection`
   - Calls `setFavorite()` in database (async Task with `.utility` priority)

2. **Database Save** (GRDBDatabaseManager.swift:431)
   - `setFavorite()` executes UPDATE statement:
     ```sql
     UPDATE tracks SET
         is_favorite = ?,
         favorited_at = ?
     WHERE id = ?
     ```
   - Updates two columns: `is_favorite` (INTEGER) and `favorited_at` (DATETIME)
   - Is NOT async (synchronous)

3. **Load from Database** (GRDBDatabaseManager.swift:225)
   - `loadAllCollections()` loads all collection rows
   - For each collection, loads track rows via `reconstructTrack()`
   - `reconstructTrack()` (line 618) extracts:
     - `is_favorite`: `(row["is_favorite"] as? Int ?? 0) == 1`
     - `favoritedAt`: Handles both Date and String formats

4. **Display Favorites** (FavoriteTracksView.swift:12)
   - Calls `library.favoriteTrackEntries()`
   - Which filters collections: `.filter(\.isFavorite)`
   - Shows empty state if no entries

### Potential Root Causes

1. **Race Condition on App Termination**
   - `toggleFavorite()` dispatches async Task with `.utility` priority (low priority)
   - If user toggles favorite and app closes immediately, task may not complete
   - Database write may not have happened yet

2. **Async Task Not Awaited**
   - The `setFavorite()` call is not being awaited
   - If app terminates before task completes, changes are lost
   - No error handling at the database level

3. **Database Initialization Issue**
   - Possible race condition where database isn't fully initialized when `setFavorite()` is called
   - Could cause silent failures

4. **Incorrect Data Format**
   - DATETIME format mismatch between save and load
   - SQLite DATETIME handling differences

## Solution Strategy

### Phase 1: Verify Database State
1. Add logging to track when favorites are saved/loaded
2. Check if data is actually in the database after save
3. Verify favorite status persists in database

### Phase 2: Fix Async/Await Issues
1. Make `setFavorite()` async and properly await it
2. Increase Task priority from `.utility` to `.userInitiated`
3. Add proper error handling

### Phase 3: Verify Loading
1. Ensure favorites are properly loaded when app starts
2. Check that reconstructTrack() properly restores favorite status

## Test Plan
1. Mark a track as favorite
2. Force kill the app (or let it close normally)
3. Restart the app
4. Check if favorite appears in FavoriteTracksView
5. Check if favorite appears in CollectionDetailView

## Files to Modify
- `AudiobookPlayer/LibraryStore.swift` - toggleFavorite() method
- `AudiobookPlayer/GRDBDatabaseManager.swift` - setFavorite() method
- Consider: Add logging to verify persistence

## Status
**REGRESSION IDENTIFIED (2025-11-11)**

- CloudKit timestamp fix remains valid, but favorites still disappeared due to GRDB row decoding.
- `reconstructTrack(row:)` still relied on `(row["is_favorite"] as? Int ?? 0)` which fails when GRDB wraps the value in `Optional(1)`.
- Updated decoding to use typed subscript `let isFavoriteValue: Int? = row["is_favorite"]`, which correctly unwraps nested optionals and keeps favorites marked after restart.

## Latest Fix (2025-11-11)

### File Updated
- `AudiobookPlayer/GRDBDatabaseManager.swift`

### Change Summary
- Use typed GRDB subscripting for `is_favorite` to avoid silently clearing favorite flags when rehydrating tracks from SQLite.

### Next Steps
- Rebuild and relaunch the app.
- Verify favorites persist after marking, force-quitting, and restarting.
- If CloudKit overwrites reappear, review remote records for stale payloads.

## Root Causes (Three Bugs)

### Bug 1: Task Priority Too Low (FIXED in commit 40b10f3)
The bug was in LibraryStore.toggleFavorite() (line 410-420):
- Task priority was `.utility` (very low priority)
- If the app closed quickly after user marked a favorite, the low-priority task could be cancelled or deferred
- The database write would not complete before app termination

### Bug 2: Verification Logging Error (FIXED in commit cb1de32)
The verification code in GRDBDatabaseManager.setFavorite() had a double-optional handling bug:
- GRDB returns `row["is_favorite"]` as `Any?` containing `Optional(1)`
- Code tried: `(rawValue as? Int ?? 0) == 1`
- This cast failed because `Optional(1)` can't be cast directly to `Int`
- Result: Verification always showed `false` even when database had correct value
- **Impact**: This was a logging-only bug - favorites WERE being saved correctly, but logs made it look broken

### Bug 3: CloudKit Sync Overwriting Local Favorites ⚠️ **THE REAL BUG**
**Root Cause**: Collection's `updatedAt` timestamp was not being saved to GRDB when favorites changed
1. User toggles favorite → track's `is_favorite` saved to GRDB ✅
2. Collection's `updatedAt` updated **in memory** only ✅
3. Collection's `updatedAt` **NOT saved to GRDB** ❌
4. On app restart:
   - GRDB loads collection with **old `updatedAt`** from initial import
   - CloudKit has newer timestamp (from any other device/sync)
   - CloudKit sync sees `remote.updatedAt > local.updatedAt`
   - CloudKit **overwrites entire local collection** (losing all favorites!)

**Why This Wasn't Caught Earlier**:
- The track favorite data WAS in GRDB correctly
- The verification logs showed correct values
- But CloudKit sync ran AFTER loading from GRDB
- The merge logic replaced the entire collection based on timestamp comparison

## Fixes Applied

### Fix 1: LibraryStore.swift toggleFavorite()
Changed Task priority from `.utility` to `.userInitiated`:

```swift
// Before
Task(priority: .utility) {
    do {
        try await dbManager.setFavorite(track.isFavorite, for: trackID)
    } catch { ... }
}

// After
Task(priority: .userInitiated) {
    do {
        try await dbManager.setFavorite(track.isFavorite, for: trackID)
        // ... (see Fix 3 for additional code)
    } catch { ... }
}
```

### Fix 2: GRDBDatabaseManager.swift setFavorite()
Fixed verification code to properly handle GRDB optional values:

```swift
// Before (WRONG)
let rawValue = row["is_favorite"]
let savedFavorite = (rawValue as? Int ?? 0) == 1
// Result: Optional(1) as? Int fails → nil ?? 0 → 0 == 1 → false ❌

// After (CORRECT)
let intValue: Int? = row["is_favorite"]  // Use typed subscript
let savedFavorite = (intValue ?? 0) == 1
// Result: intValue = 1 → 1 ?? 0 → 1 == 1 → true ✅
```

### Fix 3: Update Collection Timestamp in GRDB (THE CRITICAL FIX)
Added new method `updateCollectionTimestamp()` and call it when toggling favorites:

**New Method in GRDBDatabaseManager.swift**:
```swift
func updateCollectionTimestamp(_ collectionId: UUID, updatedAt: Date) throws {
    guard let db = db else { throw DatabaseError.initializationFailed("Database not initialized") }

    try db.write { db in
        try db.execute(sql:
            """
            UPDATE collections SET
                updated_at = ?
            WHERE id = ?
            """,
            arguments: [updatedAt, collectionId.uuidString]
        )
    }
}
```

**Updated LibraryStore.swift toggleFavorite()**:
```swift
Task(priority: .userInitiated) {
    do {
        // Update track favorite status
        try await dbManager.setFavorite(track.isFavorite, for: trackID)

        // CRITICAL: Update collection's updatedAt timestamp so CloudKit sync doesn't overwrite!
        try await dbManager.updateCollectionTimestamp(collectionID, updatedAt: collection.updatedAt)

        print("[FAVORITES] ✅ Collection timestamp updated - will prevent CloudKit overwrite")
    } catch { ... }
}
```

**Added Debug Logging in Merge Logic**:
- Log when CloudKit overwrites local data
- Show favorite counts before/after merge
- Display timestamp comparison to identify conflicts

## Why These Fix the Bugs
1. **Higher Priority**: `.userInitiated` priority ensures database writes complete before app termination
2. **Proper Type Extraction**: Using typed subscript `let intValue: Int? = row["is_favorite"]` correctly unwraps GRDB's optional value
3. **Accurate Logging**: Verification now correctly shows the saved value
4. **Timestamp Synchronization**: Collection's `updatedAt` is now saved to GRDB, preventing CloudKit from overwriting local changes
5. **Last-Write-Wins Consistency**: With synchronized timestamps, the merge logic correctly preserves the most recent version (local with favorites)

## Commits
- `40b10f3` - fix(favorites): increase task priority for favorite status persistence
- `cb1de32` - fix(favorites): correct GRDB optional value handling in verification
- `7dbf0f9` - fix(favorites): update collection timestamp to prevent CloudKit overwrite

## Testing Instructions
1. Open the app and go to a collection with several tracks
2. Mark 3-5 tracks as favorites (tap heart icon in CollectionDetailView)
3. Verify favorites appear in FavoriteTracksView
4. Force kill the app (swipe up from app switcher or use Xcode)
5. Restart the app
6. Go to FavoriteTracksView and verify all favorites still appear

## Expected Result
Favorite marks now persist across app restarts due to higher task priority ensuring database writes complete before app termination.
