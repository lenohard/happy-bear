# STT Phase 2 Completion Task

**Status**: 🔄 In Progress
**Created**: 2025-11-08
**Target**: Complete Phase 2 - Basic Transcription UI & Viewer

---

## Overview

Phase 1 (Backend Infrastructure) is complete. Phase 2 needs to deliver a working end-to-end transcription experience where users can:
1. Transcribe a single track via UI context menu
2. View and search the transcript
3. See progress and get notifications
4. Persist job state for crash recovery

---

## Phase 2 Gaps & Deliverables

### Gap 1: Transcript Viewer UI (HIGH PRIORITY)
**Status**: ❌ Not Started
**Description**: Users can create transcripts but have no way to read them.

**Deliverables**:
- [ ] `TranscriptViewerSheet.swift` - Main transcript display component
  - Full text display with timestamps
  - Tap segment → jump to playback position
  - Search box with highlighting
  - Scroll sync with playback (optional for Phase 2)

- [ ] `TranscriptViewModel.swift` - Manage transcript state
  - Load transcript from GRDB by trackID
  - Parse segments with timestamps
  - Search logic (case-insensitive substring matching)
  - Update playback position when user taps segment

- [ ] Add "View Transcript" menu option to Collection Detail
  - Only show if transcript exists (check `Transcript.jobStatus == "complete"`)
  - Launch `TranscriptViewerSheet`

**Files to Create**:
- `AudiobookPlayer/TranscriptViewerSheet.swift`
- `AudiobookPlayer/TranscriptViewModel.swift`

**Files to Modify**:
- `AudiobookPlayer/CollectionDetailView.swift` - Add "View Transcript" menu option

---

### Gap 2: Global Progress Indicator (MEDIUM PRIORITY)
**Status**: ❌ Not Started
**Description**: Users must keep TranscriptionSheet open to see progress. No background awareness.

**Deliverables**:
- [ ] Add transcription badge/HUD to main app
  - Show count of active jobs (e.g., "Transcribing 2 tracks...")
  - Tap to view detailed progress sheet
  - Auto-dismiss when all jobs complete

- [ ] Create `TranscriptionProgressOverlay.swift`
  - Display active job count
  - Show status: "queued", "uploading", "transcribing", "processing"
  - Show overall progress across all jobs

- [ ] Modify `AudiobookPlayerApp.swift`
  - Watch `TranscriptionManager.currentTrackId` to show/hide badge
  - Add overlay view near TabView

**Files to Create**:
- `AudiobookPlayer/TranscriptionProgressOverlay.swift`

**Files to Modify**:
- `AudiobookPlayer/AudiobookPlayerApp.swift` - Add badge/HUD

---

### Gap 3: Job Tracking & Retries (MEDIUM PRIORITY)
**Status**: ❌ Not Started
**Description**: `transcription_jobs` table exists but is never populated. No crash recovery or retries.

**Deliverables**:
- [ ] Populate `transcription_jobs` table on every job state change
  - Write on job creation: `status = "queued"`
  - Update on upload start: `status = "uploading"`
  - Update on Soniox response: `status = "transcribing"`, `sonioxJobID = ...`
  - Update on completion: `status = "completed"`, `completedAt = now`
  - Update on failure: `status = "failed"`, `errorMessage = ...`

- [ ] Implement exponential backoff for Soniox API errors
  - Retry failed jobs (max 3 attempts)
  - Backoff: 5s, 15s, 45s
  - Log retry attempts

- [ ] Add crash-safe resume on app restart
  - On app launch: check for jobs with `status = "uploading"` or `status = "transcribing"`
  - Resume polling for in-progress jobs

**Files to Modify**:
- `AudiobookPlayer/TranscriptionManager.swift` - Add job tracking + retries
- `AudiobookPlayer/GRDBDatabaseManager.swift` - Add job CRUD methods
- `AudiobookPlayer/AudiobookPlayerApp.swift` - Add resume-on-startup logic

---

### Gap 4: Localization Keys
**Status**: ⚠️ Partial
**Description**: Some localization keys exist, but transcript viewer needs more.

**Required Keys** (add to `Localizable.xcstrings`):
```
"view_transcript" -> "View Transcript"
"view_transcript_zh" -> "查看文本"
"search_in_transcript" -> "Search in Transcript"
"search_in_transcript_zh" -> "在文本中搜索"
"no_transcript_found" -> "No transcript available"
"no_transcript_found_zh" -> "没有文本可用"
"transcript_search_results" -> "Results for \"%@\""
"transcript_search_results_zh" -> "搜索结果: \"%@\""
"jump_to_playback" -> "Jump to Playback"
"jump_to_playback_zh" -> "跳转到播放位置"
"transcription_jobs_active" -> "Transcribing %d track(s)"
"transcription_jobs_active_zh" -> "正在转录 %d 个音轨"
```

**Files to Modify**:
- `AudiobookPlayer/Localizable.xcstrings` - Add keys above

---

### Gap 5: Testing & Documentation (LOW PRIORITY)
**Status**: ❌ Not Started
**Description**: No documented workflow for testing transcription end-to-end.

**Deliverables**:
- [ ] Document Soniox API key setup
  - Store in Keychain (via AI tab)
  - Or set in Info.plist (fallback)
  - Include API key format expectations

- [ ] Create test workflow
  - Step-by-step guide to test single track transcription
  - Expected output format
  - How to verify transcript in GRDB

**Files to Create**:
- `local/stt-phase2-testing.md` - Testing guide

---

## Implementation Order

**Stage 1: Transcript Viewer** (2-3 hours)
1. Create `TranscriptViewerSheet.swift` with basic display + tap-to-seek
2. Create `TranscriptViewModel.swift` with GRDB loading
3. Add "View Transcript" menu to `CollectionDetailView`
4. Test with existing transcripts

**Stage 2: Search & Integration** (1-2 hours)
1. Add search box to `TranscriptViewerSheet`
2. Implement search highlighting
3. Update localization strings

**Stage 3: Progress Indicator** (2-3 hours)
1. Create `TranscriptionProgressOverlay.swift`
2. Integrate into `AudiobookPlayerApp.swift`
3. Wire up with `TranscriptionManager` publishers

**Stage 4: Job Tracking & Retries** (3-4 hours)
1. Add job CRUD methods to `GRDBDatabaseManager`
2. Update `TranscriptionManager` to track job state
3. Implement exponential backoff
4. Add crash-safe resume logic
5. Test with simulated failures

**Stage 5: Testing & Documentation** (1 hour)
1. Document API key setup and usage
2. Write testing guide
3. Run full end-to-end transcription test

---

## Success Criteria

Phase 2 is complete when:
- ✅ Users can transcribe a track via context menu
- ✅ Users can view the generated transcript with timestamps
- ✅ Users can search within transcripts
- ✅ Users can tap a segment to jump to that playback position
- ✅ Progress is visible even if sheet is closed (badge/HUD)
- ✅ Jobs are tracked in database for crash recovery
- ✅ Failed jobs automatically retry with backoff
- ✅ End-to-end test runs successfully with real Soniox API key
- ✅ All new UI strings are localized (English + Chinese)

---

## Notes

- Assume GRDB models (`Transcript`, `TranscriptSegment`, `TranscriptionJob`) already exist
- Use existing `SonioxAPI` and `TranscriptionManager` infrastructure
- Follow existing UI patterns from `CollectionDetailView`, `LibraryView`
- Keep components reusable (e.g., segment viewing can be used in other contexts)

---

## References

- Phase 1 implementation: `local/stt-phase1-implementation.md`
- Architecture: `local/stt-integration.md`
- Test script: `local/test_soniox_transcription.py`
- GRDB integration: `local/structured-storage-migration.md`
