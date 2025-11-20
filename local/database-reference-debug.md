# STT Database Reference & Debug Guide

## Database Location

**Path**: `~/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite`

**Short alias** (for terminal):
```bash
DB_PATH="/Users/senaca/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite"
sqlite3 "$DB_PATH" "SELECT * FROM transcripts;"
```

---

## Database Schema

### Tables Created
```
collections          → Library collections
tags                 → Tags for tracks/collections
transcription_jobs   → Job tracking (status, retries)
playback_states      → Track playback progress
tracks               → Individual tracks
transcripts          → Transcript metadata + full text
schema_state         → Schema version tracking
transcript_segments  → Individual segments with timestamps
```

### Transcripts Table Schema
```sql
PRAGMA table_info(transcripts);

0 | id                | TEXT    | NOT NULL | PRIMARY KEY
1 | track_id          | TEXT    | NOT NULL | FK to tracks
2 | collection_id     | TEXT    | NOT NULL | FK to collections
3 | language          | TEXT    | NOT NULL | DEFAULT 'en'
4 | full_text         | TEXT    | NOT NULL | Complete transcript (4250+ chars)
5 | created_at        | DATETIME| NOT NULL | Creation timestamp
6 | updated_at        | DATETIME| NOT NULL | Last update timestamp
7 | job_status        | TEXT    | NOT NULL | DEFAULT 'pending' | Status: "complete", "pending", "failed"
8 | job_id            | TEXT    |          | Soniox job ID (nullable)
9 | error_message     | TEXT    |          | Error details if failed (nullable)
```

### Transcript Segments Table Schema
```sql
PRAGMA table_info(transcript_segments);

0 | id            | TEXT     | NOT NULL | PRIMARY KEY
1 | transcript_id | TEXT     | NOT NULL | FK to transcripts
2 | text          | TEXT     | NOT NULL | Segment text (33-120+ chars)
3 | start_ms      | INTEGER  | NOT NULL | Start time in milliseconds
4 | end_ms        | INTEGER  | NOT NULL | End time in milliseconds
5 | speaker       | TEXT     |          | Speaker ID/name (nullable)
6 | language      | TEXT     |          | Detected language (nullable)
7 | confidence    | REAL     |          | Confidence score 0.0-1.0 (nullable)
```

---

## Current State (as of 2025-11-09 12:29)

### Transcript Count
```sql
SELECT COUNT(*) as transcript_count FROM transcripts;
-- Result: 1
```

### Segment Count
```sql
SELECT COUNT(*) as segment_count FROM transcript_segments;
-- Result: 16
```

### Transcript Details
```sql
SELECT id, track_id, LENGTH(full_text) as text_length, job_status
FROM transcripts;

-- Result:
-- id                                   | track_id                           | text_length | job_status
-- 4D3660C3-95CA-4D61-B79A-F5D9B5E56D03 | 53BD6760-BA54-41B9-8EB4-3DF369... | 4250        | complete
```

### Sample Text
```
我们一起读小说，按照时间，一百年，一百部。我们读的都是文学史上的代表作。
通过这一百个故事，我们不仅可以看到一个个活生生的中国人，看到他们的血泪梦想...
(4250 characters total)
```

### Segment Sample
```sql
SELECT id, transcript_id, LENGTH(text) as segment_length, start_ms, end_ms
FROM transcript_segments LIMIT 3;

-- Result:
-- id                                   | transcript_id                      | segment_length | start_ms | end_ms
-- D4A854AA-F4BB-453B-B808-9FAB6429C0B9 | 4D3660C3-95CA-4D61-B79A-F5D9B5E56D03 | 120            | ?        | ?
-- 93FDBED2-14FC-4D43-8AC8-F148FFF27EE9 | 4D3660C3-95CA-4D61-B79A-F5D9B5E56D03 | 33             | ?        | ?
-- CC776C1F-615B-4173-9665-58674F45F02F | 4D3660C3-95CA-4D61-B79A-F5D9B5E56D03 | 94             | ?        | ?
```

---

## Debug Queries

### Check if Transcript Exists for Track
```bash
DB_PATH="/Users/senaca/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite"

# Check all transcripts
sqlite3 "$DB_PATH" "SELECT id, track_id, job_status, LENGTH(full_text) FROM transcripts;"

# Check specific track
TRACK_ID="53BD6760-BA54-41B9-8EB4-3DF369EEEC76"
sqlite3 "$DB_PATH" "SELECT * FROM transcripts WHERE track_id = '$TRACK_ID';"
```

### Check Segments for Transcript
```bash
DB_PATH="/Users/senaca/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite"
TRANSCRIPT_ID="4D3660C3-95CA-4D61-B79A-F5D9B5E56D03"

# Count segments
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM transcript_segments WHERE transcript_id = '$TRANSCRIPT_ID';"

# View all segments
sqlite3 "$DB_PATH" "SELECT id, SUBSTR(text, 1, 50), start_ms, end_ms FROM transcript_segments WHERE transcript_id = '$TRANSCRIPT_ID';"
```

### Check Job Status
```bash
DB_PATH="/Users/senaca/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite"

sqlite3 "$DB_PATH" "SELECT id, job_status, error_message FROM transcription_jobs LIMIT 10;"
```

### Get Full Transcript Text
```bash
DB_PATH="/Users/senaca/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite"
TRANSCRIPT_ID="4D3660C3-95CA-4D61-B79A-F5D9B5E56D03"

sqlite3 "$DB_PATH" "SELECT full_text FROM transcripts WHERE id = '$TRANSCRIPT_ID';" > /tmp/transcript.txt
# View first 1000 chars
head -c 1000 /tmp/transcript.txt
```

---

## Known Issues & Solutions

### Issue: Viewer Shows Blank But Data Exists

**Status**: 🔴 Investigating

**Evidence**:
- Database contains 1 complete transcript ✅
- 16 segments saved with content ✅
- 4250 characters of text ✅
- But TranscriptViewerSheet shows empty

**Possible Causes**:
1. TranscriptViewModel not refreshing after transcription completes
2. Track ID mismatch between what's displayed and what's queried
3. App cache not clearing between transcription and viewer load
4. Segments not being loaded properly in TranscriptViewModel.loadTranscript()

**Debug Steps**:
1. Restart the app (kill from Xcode)
2. Navigate to track ID: `53BD6760-BA54-41B9-8EB4-3DF369EEEC76`
3. Tap "View Transcript"
4. If still blank, add logging to `TranscriptViewModel.swift:loadTranscript()`

---

## Key Findings

1. ✅ **STT pipeline works end-to-end** - Soniox API upload, transcription, retrieval all working
2. ✅ **Data persistence works** - GRDB database correctly saves transcripts and segments
3. ✅ **Caching works** - Clicking transcribe twice doesn't re-upload (uses cached transcript)
4. ❌ **UI display broken** - TranscriptViewerSheet not showing the saved data
5. ⚠️ **May be timing issue** - Viewer sheet may load before data fully persists, or state not updating

---

## Related Files

- `TranscriptViewModel.swift` - Loads transcripts from DB (line 74-96, loadTranscript())
- `TranscriptViewerSheet.swift` - Displays transcripts (checks `viewModel.segments.isEmpty` at line 55)
- `TranscriptionManager.swift` - Saves to DB (line 289-306, saveTranscriptData())
- `GRDBDatabaseManager.swift` - Database operations

---

## Next Steps

1. Add logging to `TranscriptViewModel.loadTranscript()` to see what's actually being loaded
2. Check if segments are being filtered out somewhere
3. Verify TranscriptViewerSheet state updates after transcription completes
4. Consider adding delay/refresh trigger after transcription job finishes
