# STT Feature - Caching & Blank Transcript Issues

## Question 1: Does it re-transcribe or use cached transcript?

### Answer: **Uses cached transcript** ✅

**Location**: `TranscriptionManager.swift:373-375`

When you click "Transcribe" again on the same track, the code checks:

```swift
if let existing = try await dbManager.loadTranscript(forTrackId: trackId) {
    return existing.id  // ← Reuses existing transcript, no new upload/transcription
}
```

**Behavior**:
- First transcription: Uploads audio → Transcribes → Stores in database
- Second transcription (same track): Checks database → Finds existing → Returns immediately (no API calls)

✅ **This is correct behavior** - it prevents duplicate work and saves API costs.

---

## Question 2: Why does the transcript viewer show blank?

### Root Cause: Segments Are Empty (No data saved to database)

**Problem Flow**:

1. Transcript is **created** in database with `jobStatus="pending"` and `fullText=""` (empty)
2. Transcription **completes** in Soniox API
3. Results are **retrieved** from Soniox
4. But the transcript's `fullText` and `segments` are **NOT being saved** properly

**Evidence**:
- `TranscriptViewerSheet.swift:55` shows "no_transcript_found" when `segments.isEmpty`
- `TranscriptViewModel.swift:84` tries to load segments but gets empty array
- The segments were never inserted into the database

### Where the Data Loss Happens

**Location**: `TranscriptionManager.swift`

The code retrieves the full transcript from Soniox but the segment-saving logic may have issues:

```swift
// Line 84 in TranscriptViewModel
let loadedSegments = try await dbManager.loadTranscriptSegments(forTranscriptId: loadedTranscript.id)
// ^ Returns empty array if segments were never saved
```

### How to Debug & Fix

**Step 1: Check the Database**

Run this to see what's actually in the database after transcription:

```bash
# Check if transcript exists
sqlite3 ~/projects/audiobook-player/audiobooks.db "SELECT id, trackID, jobStatus, fullText FROM transcripts LIMIT 5;"

# Check if segments exist
sqlite3 ~/projects/audiobook-player/audiobooks.db "SELECT transcriptID, text, startTimeMs FROM transcript_segments LIMIT 5;"
```

**Step 2: What to Check in Code**

Look in `TranscriptionManager.swift` around the section where it **processes completed Soniox results**:

1. Does it parse the tokens from Soniox response correctly?
2. Does it save `fullText` to the transcript?
3. Does it insert segments into `transcript_segments` table?

**Step 3: The Fix (Likely)**

In `TranscriptionManager.swift`, after getting the transcript from Soniox API, ensure:

```swift
// 1. Update transcript with fullText
try await dbManager.updateTranscriptWithText(
    transcriptId: transcriptId,
    fullText: "...",  // ← Make sure this is populated
    jobStatus: "completed"
)

// 2. Save all segments
for segment in parsedSegments {
    try await dbManager.saveTranscriptSegment(
        transcriptId: transcriptId,
        segment: segment
    )
}
```

### Recommended Next Steps

1. **Check the database** using the SQLite commands above
2. **Review TranscriptionManager's completion handler** - see where it processes the Soniox response
3. **Verify segment parsing** - confirm tokens are being converted to TranscriptSegment objects
4. **Run the comprehensive test** to see what data Soniox actually returns vs what gets saved

---

## Files Involved

| File | Issue |
|------|-------|
| `TranscriptionManager.swift:373` | ✅ Correctly checks for existing transcripts (deduplication works) |
| `TranscriptViewModel.swift:84` | ❌ Loads empty segments array from database |
| `TranscriptViewerSheet.swift:55` | ❌ Shows blank because segments are empty |
| Database: `transcript_segments` table | ❌ Likely empty after transcription |

---

## Quick Test

Try transcribing again and check:
1. Did the sheet show "transcription_completed"? (Yes → Soniox API works)
2. When you click "View Transcript", is it blank? (Yes → Segments not saved to DB)

If both are true, the fix is in step 3 above - ensure the segment data is persisted to the database.
