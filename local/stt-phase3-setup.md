# STT Phase 3 - Implementation & Xcode Setup Guide

**Status**: 🟡 Ready for Xcode Configuration
**Date**: 2025-11-08
**Action Required**: Add missing files to Xcode build target

---

## Overview

Phase 3 implementation is complete! The following components have been created and integrated:

### ✅ Completed Components

1. **Transcript Viewer** (`TranscriptViewerSheet.swift`)
   - Full transcript display with timestamps
   - Search functionality with highlighting
   - Tap segment to jump to playback position
   - Error handling and retry logic
   - Status: File created and ready ✓

2. **Transcript ViewModel** (`TranscriptViewModel.swift`)
   - Load transcripts from GRDB
   - Parse segments with timestamps
   - Search filtering and result highlighting
   - Playback position conversion
   - Status: File created and ready ✓

3. **Progress Overlay** (`TranscriptionProgressOverlay.swift`)
   - Global HUD showing active transcription jobs
   - Progress bar and percentage display
   - Tap to open detailed progress sheet
   - Status badge for job state
   - Status: File created, **NEEDS BUILD TARGET ADDITION**

4. **Job Tracking Manager** (`TranscriptionJobManager.swift`)
   - CRUD operations for transcription jobs
   - Job status tracking (queued → uploading → transcribing → completed/failed)
   - Retry count management
   - Error message storage
   - Status: File created, **NEEDS BUILD TARGET ADDITION**

5. **Retry Manager** (`TranscriptionRetryManager.swift`)
   - Exponential backoff retry logic
   - Max 3 retry attempts with delays: 5s → 15s → 45s
   - Automatic job resumption on app startup
   - Crash-safe persistence
   - Status: File created, **NEEDS BUILD TARGET ADDITION**

6. **CollectionDetailView Integration**
   - Added "View Transcript" context menu option (long-press on track)
   - Opens `TranscriptViewerSheet` for viewing and searching
   - Integrated with existing "Transcribe Track" option
   - Status: Integration complete ✓

7. **ContentView Integration**
   - Added `TranscriptionProgressOverlay` to main app view
   - Shows badge when transcriptions are in progress
   - Tap badge to open detailed progress sheet
   - Status: Integration complete, **NEEDS FILE IN BUILD TARGET**

---

## Required Xcode Setup Steps

### Step 1: Open Xcode Project
```bash
open AudiobookPlayer.xcodeproj
```

### Step 2: Add Files to Build Target

Three files need to be added to the `AudiobookPlayer` target's Build Phases > Compile Sources:

**Files to Add**:
1. `AudiobookPlayer/TranscriptionProgressOverlay.swift`
2. `AudiobookPlayer/TranscriptionJobManager.swift`
3. `AudiobookPlayer/TranscriptionRetryManager.swift`

**Instructions**:
1. In Xcode, select the **AudiobookPlayer** project in the left sidebar
2. Select the **AudiobookPlayer** target
3. Go to the **Build Phases** tab
4. Expand **Compile Sources**
5. Click the **+** button
6. Select the three files listed above (use Cmd+Click to select multiple)
7. Ensure the **AudiobookPlayer** target checkbox is checked
8. Click **Add**

### Step 3: Verify Files Are Added

After adding, verify all three files appear in the **Compile Sources** list under **Build Phases**.

### Step 4: Clean and Rebuild

```bash
xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer \
  -destination 'generic/platform=iOS Simulator' clean build
```

Or in Xcode:
- Press `Cmd + Shift + K` to clean build folder
- Press `Cmd + B` to build

**Expected Result**: Build should complete successfully with 0 errors

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│         Audiobook Player App                    │
├─────────────────────────────────────────────────┤
│                                                 │
│  ContentView (with TranscriptionProgressOverlay)│
│      ↓                                          │
│  TabView [Library, Playing, Sources, AI, TTS] │
│                                                 │
│  Collection Detail View                        │
│      ├─ Context Menu "Transcribe Track"       │
│      │   → TranscriptionSheet                 │
│      │   → TranscriptionManager.transcribe()  │
│      │                                         │
│      └─ Context Menu "View Transcript"        │
│          → TranscriptViewerSheet              │
│          → TranscriptViewModel (GRDB loader) │
│                                                 │
│  TranscriptionManager (Environment)           │
│      ├─ SonioxAPI (network)                   │
│      ├─ TranscriptionJobManager (DB)          │
│      ├─ TranscriptionRetryManager (backoff)   │
│      └─ GRDBDatabaseManager (persistence)     │
│                                                 │
│  Progress Overlay (always visible when        │
│      transcriptions are active)               │
│      ├─ Shows badge with progress             │
│      └─ Sheet with detailed status            │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

## Data Flow

### Transcription Workflow
```
1. User long-presses track in Collection Detail
2. Selects "Transcribe Track"
3. TranscriptionSheet appears
4. User confirms transcription
5. TranscriptionManager:
   a. Creates TranscriptionJob (queued)
   b. Downloads audio from Baidu
   c. Uploads to Soniox API
   d. Updates job status (uploading → transcribing)
   e. Polls Soniox for completion
   f. Writes Transcript + TranscriptSegments to GRDB
   g. Updates job status (completed)
6. UI shows completion in progress overlay
7. User can now view transcript
```

### Viewing Transcript Workflow
```
1. User long-presses track in Collection Detail
2. Selects "View Transcript"
3. TranscriptViewerSheet opens
4. TranscriptViewModel loads transcript from GRDB
5. Display options:
   a. Full transcript with timestamps
   b. Search results with highlighting
6. User taps segment → Seek to playback position
7. Close sheet to continue playback
```

### Retry Workflow
```
1. Transcription job fails (network error, Soniox error, etc.)
2. TranscriptionRetryManager checks retry count
3. If retries < 3:
   a. Calculate backoff delay (5s, 15s, 45s)
   b. Schedule retry after delay
   c. Update TranscriptionJob.retry_count
4. If retries ≥ 3:
   a. Mark job as failed
   b. Show error in progress overlay
   c. User can retry manually
5. On app restart:
   a. Resume any jobs with status = uploading/transcribing
   b. Continue polling or retry failed jobs
```

---

## Database Schema

### Transcription Tables (Already Created)

**transcripts**
```sql
CREATE TABLE transcripts (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL UNIQUE,
    collection_id TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'en',
    full_text TEXT,
    created_at DATETIME,
    updated_at DATETIME,
    job_status TEXT NOT NULL DEFAULT 'pending',
    job_id TEXT,
    FOREIGN KEY (track_id) REFERENCES audiobook_tracks(id),
    FOREIGN KEY (collection_id) REFERENCES audiobook_collections(id)
);
```

**transcript_segments**
```sql
CREATE TABLE transcript_segments (
    id TEXT PRIMARY KEY,
    transcript_id TEXT NOT NULL,
    text TEXT NOT NULL,
    start_time REAL NOT NULL,
    end_time REAL NOT NULL,
    confidence REAL,
    FOREIGN KEY (transcript_id) REFERENCES transcripts(id)
);
```

**transcription_jobs**
```sql
CREATE TABLE transcription_jobs (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL UNIQUE,
    soniox_job_id TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    progress REAL DEFAULT 0.0,
    created_at DATETIME NOT NULL,
    completed_at DATETIME,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    last_attempt_at DATETIME,
    FOREIGN KEY (track_id) REFERENCES audiobook_tracks(id)
);
```

---

## Localization Keys (All Already Added)

All transcript-related localization keys are already in `Localizable.xcstrings`:

```
// Transcript Viewer
"view_transcript" → "View Transcript"
"search_in_transcript" → "Search in Transcript"
"no_transcript_found" → "No transcript available"
"transcript_search_results" → "Results for \"%@\""
"transcript_search_no_matches" → "No matches found"

// Progress Indicator
"transcribing_indicator" → "Transcribing..."
"transcription_progress_title" → "Transcription Progress"
"active_transcriptions" → "Active Transcriptions"
"no_active_transcriptions" → "No active transcriptions"

// Status Badges
"queued_status" → "Queued"
"uploading_status" → "Uploading"
"transcribing_status" → "Transcribing"
"completed_status" → "Completed"
"failed_status" → "Failed"

// Tips & Messages
"transcription_in_progress" → "Transcription in Progress"
"transcription_processing_message" → "Processing audio with Soniox..."
"transcription_tip_background" → "Transcriptions continue in the background"
"transcription_tip_view" → "View completed transcripts anytime from the context menu"
"transcription_error_occurred" → "Transcription Error"
```

---

## Testing the Feature

### Phase 3 Complete End-to-End Test

1. **Setup API Key**
   - Go to TTS tab
   - Paste your Soniox API key in the Soniox credential section
   - API key is saved to Keychain

2. **Start Transcription**
   - Go to Library tab
   - Select a collection
   - Long-press on a track
   - Select "Transcribe Track"
   - Confirm transcription start
   - Watch progress badge appear at top of app

3. **Monitor Progress**
   - Progress badge shows transcription status
   - Tap badge to open detailed progress sheet
   - View job status: uploading → transcribing → completed
   - Can close progress sheet and continue using app

4. **View Transcript**
   - Once transcription completes
   - Long-press same track
   - Select "View Transcript"
   - See full transcript with timestamps

5. **Search Transcript**
   - In transcript viewer
   - Type search term in search box
   - See matching segments highlighted
   - Tap segment to jump to playback position

6. **Retry Failed Transcription**
   - If transcription fails, error shows in progress sheet
   - TranscriptionRetryManager automatically retries up to 3 times
   - Exponential backoff: 5s → 15s → 45s
   - If all retries fail, user sees error message

7. **Crash Recovery**
   - Start transcription of a long track
   - Force-quit app during transcription
   - Restart app
   - Resume logic automatically continues polling

---

## Files Modified / Created

### Created Files (Need Build Target Addition)
- `AudiobookPlayer/TranscriptionProgressOverlay.swift` ⚠️
- `AudiobookPlayer/TranscriptionJobManager.swift` ⚠️
- `AudiobookPlayer/TranscriptionRetryManager.swift` ⚠️

### Modified Files (Already Complete)
- `AudiobookPlayer/CollectionDetailView.swift` ✓
  - Added `trackForViewing` and `showTranscriptViewer` state
  - Added transcript viewer sheet presentation
  - Added "View Transcript" context menu option

- `AudiobookPlayer/ContentView.swift` ✓
  - Wrapped TabView in ZStack with overlay alignment
  - Added `TranscriptionProgressOverlay()` component

### Existing Files (Already Complete)
- `AudiobookPlayer/TranscriptViewerSheet.swift` ✓
- `AudiobookPlayer/TranscriptViewModel.swift` ✓
- `AudiobookPlayer/TranscriptionSheet.swift` ✓
- `AudiobookPlayer/TranscriptionManager.swift` ✓
- `AudiobookPlayer/GRDBDatabaseManager.swift` ✓
- `AudiobookPlayer/Localizable.xcstrings` ✓

---

## Troubleshooting

### Build Error: "Cannot find 'TranscriptionProgressOverlay'"
**Solution**: Add `TranscriptionProgressOverlay.swift` to build target (Step 2 above)

### Build Error: "Cannot find 'TranscriptionJobManager'"
**Solution**: Add `TranscriptionJobManager.swift` to build target (Step 2 above)

### Build Error: "Cannot find 'TranscriptionRetryManager'"
**Solution**: Add `TranscriptionRetryManager.swift` to build target (Step 2 above)

### Transcript Viewer Not Showing Menu Option
**Possible Cause**: File not in build target
**Solution**: Verify `TranscriptViewerSheet.swift` is in build target

### Progress Overlay Not Appearing
**Possible Cause**: Overlay not in ContentView
**Solution**: Verify `TranscriptionProgressOverlay()` is in ContentView body

### Jobs Not Persisting After App Restart
**Possible Cause**: TranscriptionJobManager not in build target
**Solution**: Add to build target and ensure `TranscriptionRetryManager` is also added

---

## Next Phase: Phase 4 (Polish & Distribution)

Once Phase 3 is fully working:
- [ ] Unit tests for TranscriptionJobManager and RetryManager
- [ ] UI/UX refinement for progress sheet
- [ ] Performance optimization for long transcripts
- [ ] Backend-less batch transcription support
- [ ] SRT/VTT export functionality
- [ ] Transcript caching strategy

---

## References

- STT Integration Architecture: `local/stt-integration.md`
- Phase 2 Completion: `local/stt-phase2-completion.md`
- GRDB Integration: `local/structured-storage-migration.md`
- Soniox API Docs: https://soniox.com/docs
- Speech-to-Text Knowledge Base: `~/knowledge_base/references/speech_to_text/`
