# Bug: Playing Tab Shows Wrong Track on App Restart

**Status**: ✅ FIXED
**Date**: 2025-11-14
**Commits**:
- `0e04da8` - Wait for library to load before rendering playing card
- `02dc8e1` - Persist lastPlayedTrackId when saving playback state

## Problem (Updated)
When the app was restarted, the Playing tab showed a fixed track and didn't update to reflect the most recently played track. Only the playback time position would update for that same track.

**Example**:
- User plays Track A (position 45:30)
- User then plays Track B (position 12:15)
- User closes and restarts app
- Playing tab still shows Track A at various positions
- Track B never appears, even though it was played most recently

## Root Causes (TWO issues found and fixed)

### Issue #1: Library Loading Race Condition (Fixed in `0e04da8`)
The initial analysis was correct - the Playing tab was trying to render before the library finished loading. This is fixed by waiting for `library.isLoading` to complete.

### Issue #2: lastPlayedTrackId Not Being Persisted to Database (Fixed in `02dc8e1`) ⭐ **The Real Culprit**

**How it happened**:
1. When a track plays, `recordPlaybackProgress()` is called from `ContentView.syncPlaybackState()`
2. This updates `collection.lastPlayedTrackId = trackID` **in memory** in the LibraryStore
3. To optimize database writes, only `savePlaybackState()` is called to update the `playback_states` table
4. The comment in the code even says:
   ```swift
   // Note: collection.updatedAt and lastPlayedTrackId updates are kept in memory
   // but deferred from database to avoid high-frequency full collection saves
   ```
5. When the app restarts and loads from the database, it loads the OLD `lastPlayedTrackId` value that was never updated in the DB
6. The result: Playing tab always shows whatever track was saved last time, ignoring recent plays

**The bug**: `GRDBDatabaseManager.savePlaybackState()` only updated the `playback_states` table, not the `collections` table's `last_played_track_id` field.

## Solutions

### Fix #1: Wait for Library Load (ContentView.swift)
Added `@State private var libraryLoaded = false` and gated the fallback playback on it. See commit `0e04da8`.

### Fix #2: Persist lastPlayedTrackId to Database (GRDBDatabaseManager.swift)
Modified `savePlaybackState()` to also execute an UPDATE statement:
```swift
// Also update the last_played_track_id in the collection
try db.execute(sql:
    """
    UPDATE collections
    SET last_played_track_id = ?, updated_at = ?
    WHERE id = ?
    """,
    arguments: [
        trackId.uuidString,
        Date(),
        collectionId.uuidString
    ]
)
```

Now both the playback position AND the lastPlayedTrackId are persisted atomically in a single write transaction.

## Testing
- ✅ Build succeeds with 0 errors
- ✅ Both fixes committed
- Pending manual testing: Play Track A, then Track B, restart app, verify Playing tab shows Track B

## Lessons Learned

### 1. **Database Persistence Gaps**
- When optimizing database writes to avoid full collection saves, make sure to track which fields still need to be persisted
- A field updated in-memory but not in the database will revert to the old value on app restart
- Document which fields are kept in-memory vs persisted

### 2. **Testing Persistence**
- When implementing async load + persistence, test both:
  - In-app behavior (what you see before restart)
  - Persistence behavior (what you see after restart)
- It's easy to miss persistence issues if you only test the first scenario

### 3. **Comments as Bugs**
- The comment "deferred from database" was actually documenting a bug
- If something is only in-memory and "deferred", it might never get saved
- Critical fields like "last played track" should always be persisted

## Files Changed
- `AudiobookPlayer/ContentView.swift`: Wait for library load before rendering
- `AudiobookPlayer/GRDBDatabaseManager.swift`: Save lastPlayedTrackId to database

## Related Files
- `AudiobookPlayer/LibraryStore.swift`: recordPlaybackProgress() logic
- `AudiobookPlayer/DatabaseSchema.swift`: Schema definition

