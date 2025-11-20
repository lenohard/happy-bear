# Migration Data Loss Debug - Session 2025-11-07

**Status**: ✅ ALL BUGS FIXED - Ready for Full Test
**Commits**: `1660eb0`, `c993d71`, `bf07f8d`
**Priority**: Critical (data loss on migration)

---

## Summary

Three critical bugs were discovered and fixed during migration testing:

### **Bug #1** ✅ FOREIGN KEY Constraint (Commit: `c993d71`)
- **Error**: `SQLite error 19: FOREIGN KEY constraint failed`
- **Cause**: Tried to delete collection before deleting dependent tracks
- **Fix**: Delete in correct order (playback_states → tracks → tags → collections)

### **Bug #2** ✅ Collection Reconstruction Fails (Commit: `bf07f8d`)
- **Error**: `Failed to reconstruct collection from row`
- **Root Cause**: GRDB returns DATETIME columns as ISO 8601 strings, not Date objects
- **Evidence**: Logs showed `Optional<DatabaseValueConvertible>` for date fields
- **Fix**: Use ISO8601DateFormatter to parse date strings from SQLite

### **Bug #3** ✅ Backup File Already Exists (Commit: `1660eb0`)
- **Error**: `Code 516: File exists` when copying backup
- **Cause**: Second migration attempt failed because backup from first attempt existed
- **Fix**: Remove existing backup before creating new one

---

## Bugs Details
**Error**: `SQLite error 19: FOREIGN KEY constraint failed - while executing DELETE FROM collections WHERE id = ?`

**Root Cause**:
- We try to delete the collection first
- But tracks still reference that collection via foreign key
- SQLite enforces referential integrity

**Current Code** (WRONG):
```swift
try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [...])
// Then insert collection
// Then insert tracks <- TOO LATE, DELETE ALREADY FAILED
```

**Solution**:
Delete in correct dependency order:
1. Delete playback_states (refs tracks)
2. Delete tracks (refs collections)
3. Then insert collection
4. Then insert tracks
5. Then insert playback_states

OR simply use INSERT OR REPLACE instead of DELETE+INSERT

---

### Bug #2: Collection Reconstruction Fails ❌
**Error**: `[GRDB] Failed to reconstruct collection from row`

**Evidence**:
- Rows ARE fetched (Found 42 tracks, 71 tracks)
- But reconstruction returns nil
- One of these fields is missing/wrong type:
  - id (TEXT)
  - title (TEXT)
  - cover_kind (TEXT)
  - created_at (DATETIME)
  - updated_at (DATETIME)
  - source_type (TEXT)
  - source_payload (TEXT)

**Current Code** (lacks diagnostics):
```swift
guard let id = collectionRow["id"] as? String,
      let title = collectionRow["title"] as? String,
      let coverKindStr = collectionRow["cover_kind"] as? String,
      let createdAt = collectionRow["created_at"] as? Date,  // <- MIGHT FAIL HERE
      let updatedAt = collectionRow["updated_at"] as? Date,  // <- OR HERE
      let sourceTypeStr = collectionRow["source_type"] as? String,
      let sourcePayload = collectionRow["source_payload"] as? String else {
    return nil  // WE DON'T KNOW WHICH ONE FAILED
}
```

**Solution**: Add logging to identify which field is failing

---

## Fixes to Apply

### Fix #1: Correct Deletion Order in saveCollection()
```swift
// Before insert, properly delete existing data in reverse dependency order
try db.execute(sql: "DELETE FROM playback_states WHERE collection_id = ?", arguments: [...])
try db.execute(sql: "DELETE FROM tracks WHERE collection_id = ?", arguments: [...])
try db.execute(sql: "DELETE FROM tags WHERE collection_id = ?", arguments: [...])
try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [...])
```

### Fix #2: Add Logging to reconstructCollection()
```swift
guard let id = collectionRow["id"] as? String else {
    print("[GRDB] Failed to get id")
    return nil
}
guard let uuid = UUID(uuidString: id) else {
    print("[GRDB] Failed to parse UUID from id: \(id)")
    return nil
}
guard let title = collectionRow["title"] as? String else {
    print("[GRDB] Failed to get title")
    return nil
}
// ... etc for each field
```

---

## Logs Analysis

Migration shows:
```
[GRDB] Found 42 tracks for collection ...
[GRDB] Failed to reconstruct collection from row
```

This means:
- ✅ Tracks table has data (42 rows)
- ✅ Collections row exists and can be fetched
- ❌ One of the collection row fields has wrong type

Most likely culprit: **DATETIME fields** (createdAt, updatedAt)
- JSON may store them as ISO8601 strings
- GRDB may not automatically convert them back to Date

---

## Test Plan

1. Apply Fix #1 (correct deletion order)
2. Apply Fix #2 (add field-level logging)
3. Run migration again
4. Check logs to see which field fails in reconstructCollection
5. Fix the field type/conversion issue

---

