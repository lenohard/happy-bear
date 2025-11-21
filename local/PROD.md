# Current Features & Bugs
### Feat: use tarnscrit as context to chat with ai

### Feat: add feeddbuck for click or drag the bubbble, jjust liek the ios assssitantBubble will enlarge upon interaction. 

### make the bubble to show the playing percentage?

### soniox file list and delte manuagement
**Doc**: `local/task-tts-files-management.md`
**Notes**: Provide a Files page under the TTS tab so folks can inspect every Soniox upload and swipe to delete any leftovers.

### Bug: frequent and random crash during generating summary.

### Feat: update the token count so far during the generating of the summary.

### Support Reasonning Models
Doc: `local/support-reasoning-models.md`
Notes: Audit the current AI usage, add a toggle for reasoning-enabled tester jobs, capture `message.reasoning` + `reasoning_details`, and surface it alongside career usage metrics.

### Bug: AI credit last updated label loops every second
Doc: `local/bug-ai-credit-last-update.md`
Notes: Balance's text should only change after a manual/initial refresh, not every second while idle.

### Add a indicator in collectionDetail page for the track with summary.
Doc: `local/collection-detail-summary-indicator.md`
Notes: Surface a small icon on each track row to signal that an AI-generated summary is already available.

### Feat: Track summary in transcript viewer
Doc: `local/feat-transcript-view-summary.md`
Notes: Show the existing Track Summary card whenever the transcript viewer is opened from a collection detail track row so listeners can read/seek via the summary from the same context.

### summary 的重新生成和生成用同一个按钮 at the end of the title line of 'track summary'
Doc: `local/task-track-summary-button.md`
Notes: Move the single (Re)Generate CTA into the Track Summary title row so users always tap the same button whether creating or refreshing a summary, and drop the duplicate buttons from the body states.

### Feat: Genreate Audiobook Using STT and add Background Music

### Feat: Collection Refresh

### Feat: Random Play For musical collection

# History: Completed Features & Bugs

## ✅ Completed Features
### Feat: AI Tab Navigation & UI Refactoring
**Doc**: `local/feat-ai-tab-refactoring.md`
**Notes**: Complete redesign of AI tab with separated navigation sections, modern card-based job list with swipe-to-delete, collapsible provider sections for models (default closed, auto-expand on search), provider logos from assets, and simplified API key editing (tap-to-edit, no "Edit" button). Fixed long-press navigation issue by separating NavigationLinks from text field section.
**Commit**: `4ce7aee` - refactor: redesign AI tab navigation and UI


### Bug: Floating bubble hidden on Playing tab
**Doc**: `local/feat-floating-playback-bubble.md`
**Notes**: Bubble was hidden when on the Playing tab and wouldn't appear at app start. Removed the tab-based conditional check in ContentView.swift so the bubble stays visible on all tabs.
**Commit**: `94f35b8` - fix: floating bubble now visible on all tabs

### Bug: AI tester job stuck running after crash
Doc: `local/bug-ai-job-stuck-running.md`
Notes: Mark lingering `running/streaming` AI tester jobs as failed on relaunch so the Run button unlocks, and kick queued jobs so they resume.

### Bug: Transcription sheet stalls on iPhone
Doc: `local/bug-transcription-upload-stage.md`
Notes: On-device transcript sheet never advances past Downloading and eventually shows a network error; instrument stages + ensure upload kickoff happens on main thread.

### Bug: Playing card transcript status + stats stale
Doc: `local/bug-playing-card-transcript-status.md`
Notes: Starting transcription from the playing card never updates its status chip when the job finishes, and the summary card shows 0 segments/characters despite an existing transcript.

### Feat: Floating Playback Bubble
Doc: `local/feat-floating-playback-bubble.md`
Notes: Persistent floating bubble for quick play/pause + jump to Now Playing without navigating.

### Feat: Track transcript summaries & sections
Doc: `local/feat-track-summary.md`
Notes: Auto-generate an overall track summary plus timestamped sections derived from transcripts; requires LLM pipeline + new UI entry point.

### Feat: AI Background Generation Jobs
Doc: `local/task-ai-background-jobs.md`
Notes: Persist AI chat/repair/summarization jobs with a shared manager + UI so work continues while navigating or when the app is suspended.
### Task: Transcript repair controls refresh
Doc: `local/task-transcript-repair-controls.md`
Notes: Compact repair mode toggles/slider, add stats card, shrink select label.

### Bug: Transcript initial focus regression
**Doc**: `local/bug-transcript-initial-focus.md`
**Notes**: Transcript sheet should auto-scroll to the currently playing segment immediately upon opening; currently it only catches up when the next segment boundary fires.

### Bug: Delete confirmation popup anchored at top
**Doc**: `local/bug-confirmation-popup.md`
**Notes**: Track + transcript deletion dialogs appear near the nav bar instead of centered/on-row, making it hard to see which track will be removed.

### Bug: 20s segmentation ignores punctuation
**Doc**: `local/bug-transcription-20s-punctuation.md`
**Notes**: The 20-second segment cap should prefer splitting at nearby commas/Chinese punctuation to avoid cutting phrases mid-token.

### Feat: Collection description display & editing
**Doc**: `local/feat-collection-description.md`

### Feat: TTS Job Controls & History
**Doc**: `local/task-tts-job-controls.md`
**Notes**: Hide completed/failed jobs by default, add history sheet, and surface pause/resume/retry/delete actions per job.

### Feat: Transcription Sheet Process Details
**Doc**: `local/task-transcription-process-ui.md`
**Notes**: Show phase-by-phase download/upload/transcribe progress with size indicators and add a context input that defaults to collection + track metadata.

### Feat: Default Playing Tab
**Doc**: `local/task-default-playing-tab.md`
**Notes**: Start the app on the Playing tab instead of Library; keep other tab behaviors intact.

### Bug: AI tab pricing + default selection
**Doc**: `local/task-ai-tab-fixes.md`
**Notes**: Fix incorrect $/M token math, auto-scroll/highlight default model, and collapse other provider groups by default for clearer focus.

### Feat: Support Baidu FIle Browser audio directly playing. 
**Doc**: `local/baidu-browser-direct-play.md`
**Sheet polish & CTA gating**: `local/task-baidu-direct-play-sheet.md`

### Feat: Transcript Viewer Auto Focus
**Doc**: `local/feat-transcript-autoscroll.md`
**Notes**: Auto-scroll the transcript sheet to the active playback segment when opened from Now Playing and keep it synced while audio progresses.

### Feat: Playback Speed Controls
**Doc**: `local/feat-playback-speed.md`
**Notes**: Remember the user's preferred speed, surface quick presets (0.5×–3×), and expose a slider on the Playing tab that updates AVPlayer + lock screen metadata immediately.

### Feat: Lock-Screen Scrubbing
**Doc**: `local/lockscreen-playback-position.md`
**Notes**: Wire up `MPRemoteCommandCenter.changePlaybackPositionCommand` so Control Center/lock screen sliders can seek and keep metadata in sync.

### Bug: Transcript segments exceed 20 seconds
**Doc**: `local/task-transcript-segmentation-20s.md`
**Notes**: Current grouping only respects punctuation and speaker changes. Add a 20-second cap so long monologues still split into readable segments.

### Bug: Transcript Viewer Segment Tap + Search Layout
**Doc**: `local/bug-transcript-viewer-selection-search.md`
**Notes**: Segment taps should not hijack unrelated tracks, and search mode must preserve multiline rows without truncation.

### Feat: React Native Migration
**Doc**: `local/react-native-migration-plan.md`
**Progress Log**: `local/task-react-native-migration.md`
**Notes**: Expo + Tamagui rewrite lives in `react-native-app/`; see task doc for daily updates.

### iCloud Sync.
- FYI: Personal Team/free development certificates cannot enable iCloud or CloudKit, so wait until the paid Apple Developer Program account is active before adding the iCloud capability or entitlements in Xcode. Builds will be rejected if we try to force those entitlements now.

### Feat: AI integration. Such as Batch rename
**Doc**: `local/ai-gateway-openai-compatible.md`, `local/ai-tab-integration.md`, `local/task-ai-tab-model-catalog-improvements.md`
**Cache refresh**: `local/task-ai-tab-cache-refresh.md`
- **Logos script**: `local/task-provider-logo-download.md`
- **API key card refresh**: `local/task-api-key-card-refresh.md` (two-line layout with reveal + save/edit controls for both AI + TTS tabs)

### Feat: AI Transcript Repair
**Doc**: `local/ai-transcript-repair.md`
**Task Log**: `local/task-ai-transcript-repair-impl.md`
**Notes**: Use in-app LLM providers to rewrite low-confidence transcript segments while preserving timestamps/speaker metadata; requires storage plan for edited text + user consent flow.


### Feat: Data export and import 
**Doc**: `local/export-import-user-data.md`
**Notes**: Zip-based backup/restore covering collections, progress, transcripts, settings, plus optional credential export with conflict-safe import flow. V1 backup+restore UI shipped 2025-11-14; tests + QA checklist pending.

### Opt: Large Import Scalability
**Doc**: `local/large-import-scalability.md`
**Notes**: Stream Baidu directory listings, lift the 500-track cap, and keep the UI responsive during large imports.

### Opt: Library UI Performance
**Doc**: `local/library-ui-performance.md`
**Notes**: Optimize collection/track rendering and derived calculations so lists scale smoothly beyond 1 000 tracks.

### Feat: Topic, Research, Podcast Genrate

### Feature: Audio Cache Management
**Status**: ✅ DONE
**Description**: Progressive buffering with 10-day TTL and LRU cleanup
**Files**: `local/Cache.md`
**Details**:
- Phase 1: Core caching infrastructure (AudioCacheManager, CachedAudioAsset)
- Phase 2: Progressive buffering (AudioCacheDownloadManager, CacheProgressTracker)
- Phase 3: UI & user feedback (cache status indicators, management sheet)
- Phase 3.1: Debug tools toggle
**Key Achievement**: Resume from saved position < 100ms, automatic cache cleanup, background downloads
**Commit**: `39600ea` - feat(cache): complete Phase 2 progressive buffering implementation

### Feature: Baidu File Browser Search Optimization
**Status**: ✅ DONE
**Description**: Improved search UX and removed problematic UI toggles
**Files**: `local/baiduBrowserImprove.md`
**Details**:
- Removed "Audio Files Only" toggle for cleaner UI
- Simplified search interface for better UX
**Rationale**: Technical complexity of detecting search field focus in SwiftUI outweighed UX benefit
**Commits**: `e6f6c2f` (Enhancement 3), bug fixes for freezing and toggle issues

### Feature: Collections Architecture
**Status**: ✅ DONE
**Description**: Library-based collection management with Baidu Netdisk import
**Files**: `local/collection.md`
**Details**:
- Collections stored as JSON (future migration to SwiftData)
- Per-track playback state tracking
- Collection builder with recursive folder scanning
- Cover art with gradient generation
- CloudKit sync (optional, gated by Info.plist flag)
**Key Models**: AudiobookCollection, AudiobookTrack, TrackPlaybackState, CollectionCover
**Commits**: `6d64515`, `22752e2`, `8e4712c`, and others

### Feature: Multi-Language Support (English & Chinese)
**Status**: ✅ DONE (Phase 1 & 2 Complete)
**Description**: Localization for English (en) and Simplified Chinese (zh-Hans)
**Files**: `local/localization.md`
**Details**:
- Phase 1: String key migration (62 strings identified and migrated)
- Phase 2: Chinese translations added
- Phase 3: Device verification pending
**Files Modified**: Localizable.xcstrings, en.lproj/Localizable.strings, zh-Hans.lproj/Localizable.strings
**Commit**: `8e4712c` - Implement multi-language support (English & Chinese)

### Bug: Collection Item Navigation Not Working
**Status**: ✅ DONE
**Description**: Collection items didn't navigate to detail view when tapped
**Files**: `local/collection-item-navigation-fix.md`
**Root Cause**: NavigationLink with EmptyView() label and opacity(0) was not tappable
**Solution**: Used NavigationLink(isActive:) with custom Binding for proper state sync
**Files Modified**: AudiobookPlayer/LibraryView.swift
**Commit**: `4ae5e03` - fix(library): restore collection item navigation with tap gesture

### Bug: Lock Screen Controls & Bluetooth Headset Actions
**Status**: ✅ DONE
**Description**: Lock screen never displayed track info; headset buttons didn't work
**Solutions**:
- Added MPRemoteCommandCenter handlers for play/pause/next/previous
- Implemented MPNowPlayingInfoCenter for track metadata display
- Added lock screen artwork support (solid colors, local images, remote URLs)
**Files Modified**: AudiobookPlayer/AudioPlayerViewModel.swift
**Commits**: `e502ba5` (lock screen controls), artwork support follow-up

### Bug: App Freezes When Opening Baidu Netdisk Browser
**Status**: ✅ DONE
**Description**: UI became unresponsive when opening file browser
**Root Cause**: Infinite update loop from onReceive(Just(_)) publishers
**Solution**: Replaced with .onChange(of:) modifiers that only fire on actual changes
**Files Modified**: AudiobookPlayer/BaiduNetdiskBrowserView.swift

### Bug: Next Track Shows as Playing But Audio Stalls
**Status**: ✅ DONE
**Description**: When a track finished, UI jumped to next but playback was silent
**Root Cause**: AVPlayer waited to minimize stalling before starting new item
**Solution**: Disabled automaticallyWaitsToMinimizeStalling, used playImmediately(atRate:)
**Files Modified**: AudiobookPlayer/AudioPlayerViewModel.swift

### Bug: Recursive Search Toggle Not Working
**Status**: ✅ DONE
**Description**: Search toggle was non-functional
**Solution**: Removed toggle, always use recursive search (more useful default behavior)
**Files Modified**: BaiduNetdiskBrowserView.swift, BaiduNetdiskBrowserViewModel.swift

### Bug: UI Inconsistency - Sources Tab & Import Button Styles
**Status**: ✅ DONE
**Description**: Redundant add button in Sources tab, inconsistent button styles
**Solution**: Removed redundant button, unified import button styling, added Local Files placeholder
**Files Modified**: LibraryView.swift, SourcesView.swift, Localizable.xcstrings
**Commit**: `5c6258d`

### Bug: Cache Playback Failure
**Status**: ✅ DONE
**Description**: Cached tracks failed to play after app restart
**Files**: `local/cache-playback-bug.md`
**Root Cause**: Cache files saved with `.cache` extension instead of preserving original audio file extension (`.mp3`, `.m4a`, `.flac`), causing AVPlayer to fail codec identification
**Solution**: Modified cache system to extract and preserve file extensions from original filenames
**Files Modified**: AudioCacheManager.swift, AudioPlayerViewModel.swift, AudioCacheDownloadManager.swift
**Commit**: `1b5ab67` - fix(cache): preserve audio file extensions for cached tracks

### Bug: Track Selection Feedback & Folder Selection
**Status**: ✅ DONE (2025-11-05)
**Description**:
1. No visual feedback when clicking a track to select it
2. Can't select folders - clicking the checkbox navigated into the folder instead of selecting it

**Root Causes**:
1. TrackPickerView passed `onSelectFile` instead of `onToggleSelection`, so checkboxes never appeared
2. BaiduNetdiskBrowserView always navigated into folders (single button action)
3. toggleSelection() explicitly guarded against folders

**Solutions**:
1. TrackPickerView now passes `onToggleSelection` callback and `selectedEntryIDs` to enable multi-select mode
2. Split BaiduNetdiskBrowserView button actions:
   - Checkbox click: toggle selection (visible for all items in multi-select mode)
   - Folder name/icon click: navigate into folder
3. Removed guard in toggleSelection() to allow folder selection

**Files Modified**:
- AudiobookPlayer/TrackPickerView.swift
- AudiobookPlayer/BaiduNetdiskBrowserView.swift

**Commit**: `70b4816` - fix(track-picker): add visual feedback for track selection and enable folder selection

**UX Improvements**:
- Checkboxes visible immediately when adding tracks
- Clear distinction between selection action (checkbox) and navigation action (folder name)
- Users can select entire folders or individual tracks

### Task: App Icon Refresh
**Status**: 🆕 TODO
**Description**: Update all AppIcon variants to the bear artwork and ensure launch screen uses the correct image.
**Files**: `local/app-icon-refresh.md`
**Notes**: Generate missing 20pt/29pt/40pt icon sizes for iPhone and iPad notifications/settings.

## Blocked Features

### Feature: Siri Control
**Status**: ⏸️ Blocked - Requires paid Apple Developer account
**Reference**: local/siri-control-implementation.md
**Description**: Enable voice control via Siri to continue play a specific collection.
**Blocker**: Free/Team provisioning profiles do not support `com.apple.developer.appintents` entitlement.

**Session 2025-11-05 Final Status**:
- ✅ Phase 1 & 2 Complete: All App Intents scaffolding created (AudiobookCollectionEntity, Query, Intent, Shortcuts)
- ✅ Phase 3: Added 13 Siri localization keys (English + Chinese)
- ✅ Setup: iOS 17.0 deployment target, entitlements configuration
- ❌ **Blocked**: Cannot proceed to device testing without paid Apple Developer membership
  - Free accounts cannot create provisioning profiles with App Intents entitlement
  - All code and infrastructure saved in branch: `feature/siri-control-wip` (commit: `ba67470`)
- **Action**: When account upgraded to paid, restore from WIP branch and proceed with Phase 4 device testing

### Opt: Baidu Browser Sheet Compact Layout
**Status**: Done
**Reference**: `local/baidu-browser-compact.md`
**Description**: Tighten the Baidu picker current-path row, drop the redundant top "已选择" header (footer already shows count), and open the picker sheet at a taller detent so more files are visible.


### Feat: Handle-pick tracks to add into a Collection. Or removal
**Status**: 🔄 COMPLETE ✅ 
`local/hand-pick-tracks.md` for implementation details

### Feat: Title Edit
**Status**: 🟢 Done
**Reference**: `local/title-edit.md`
**Notes**: Add per-track title editing support on collection detail page; align on scope and persistence before implementation.

### Opt: Structured Storage Migration
**Status**: ✅ COMPLETE - Migration working in production
**Doc**:
  - `local/task-grdb-migration-2025-11-06.md` (previous session)
  - `local/task-grdb-api-fixes-2025-11-07.md` (Phase 5 - API compatibility fixes ✅)
  - `local/grdb-integration-guide.md` (implementation guide)
  - `local/structured-storage-migration.md` (architecture & rationale)
**Notes**: Replace single-file JSON persistence with a structured store that can scale to 100+ collections and thousands of tracks.

**Session 2025-11-07 Final Status** ✅:
- ✅ Phase 4: Files added to Xcode build target
- ✅ Phase 5: Fixed all GRDB API compatibility errors (15 total fixes)
- ✅ Phase 6: Fixed DATETIME parsing (SQLite format handling)
- ✅ Phase 7: Fixed GRDB Row integer extraction (type-annotated subscripts)
- ✅ Phase 8: Automatic legacy JSON cleanup after successful migration
  - Migrates 2 collections with 113 tracks successfully
  - Creates backup at audiobooks.json.backup
  - Removes legacy audiobooks.json file automatically
  - Prevents re-migration attempts

**Key Commits**:
- `f56464a` - DATETIME parsing fix
- `a6d33e5` - GRDB Row integer extraction fix
- `2ef5f23` - Automatic legacy JSON cleanup (Plan A)

**Current Build Status**: ✅ PRODUCTION READY
- Xcode project: Files successfully added to build target ✅
- Compilation: ✅ 0 errors, 0 warnings
- Runtime: ✅ Migration verified with real data (2 collections, 113 tracks)
- GRDB API calls: ✅ All fixed
- Type safety: ✅ Verified

### Bug: High-Frequency GRDB Collection Saves During Playback
**Status**: ✅ FIXED
**Doc**: `local/performance-grdb-redundant-saves.md`
**Issue**: Collection was being saved 5+ times per second, each save doing full DELETE+INSERT of all 100+ tracks
**Root Cause**: `LibraryStore.recordPlaybackProgress()` called `saveCollection()` on every `currentTime` change
**Solution**: Use `savePlaybackState()` (INSERT OR REPLACE) instead, avoiding full collection re-writes
**Impact**: ~80% reduction in database writes during playback
**Commit**: `a8803db` - fix(perf): optimize playback progress recording to avoid full collection saves

### Feat: Integrate the STT service, using sonoix
**Status**: Phase 3 Implementation Complete  Done
**Doc**: `local/stt-integration.md`
**Reference**: `local/test_soniox_transcription.py`
**Phase 2 Plan**: `local/stt-phase2-completion.md`
**Phase 3 Setup**: `local/stt-phase3-setup.md` ← READ THIS FIRST
**Xcode Setup**: `local/stt-phase2-xcode-setup.md`
**Commits**:
  - `5683f0b` - Stage 1: Transcript viewer UI and search
  - `0d9088f` - Stage 2: Progress indicator overlay
  - `ab0dded` - Stage 3: Job tracking and retry logic
  - `428e80a` - feat(stt): add visual indicator for transcribed tracks
  - `a498d5e` - fix(stt): reload API key on demand before transcription
**Status Update (2025-11-08)**:
  - ✅ Transcript Viewer (`TranscriptViewerSheet.swift`) - UI for viewing & searching transcripts
  - ✅ Transcript ViewModel (`TranscriptViewModel.swift`) - GRDB loading & search logic
  - ✅ Progress Overlay (`TranscriptionProgressOverlay.swift`) - Global job progress HUD
  - ✅ Job Tracking Manager (`TranscriptionJobManager.swift`) - DB CRUD operations
  - ✅ Retry Manager (`TranscriptionRetryManager.swift`) - Exponential backoff + crash recovery
  - ✅ CollectionDetailView Integration - "View Transcript" context menu option
  - ✅ ContentView Integration - Progress overlay display
  - ⚠️ **CRITICAL**: Three files need to be added to Xcode build target:
    - TranscriptionProgressOverlay.swift
    - TranscriptionJobManager.swift
    - TranscriptionRetryManager.swift
**Status Update (2025-11-09)**:
  - ✅ Transcript Status Indicator - Visual indicator showing which tracks have completed transcripts
    - Added `hasCompletedTranscript()` method to GRDBDatabaseManager
    - Added transcription status caching in CollectionDetailView
    - Display blue text.alignleft icon next to track name when transcript exists
    - Loads transcript status on view appear and collection change
    - Added "transcript_available" localization key (English + Chinese)
  - ✅ Fixed 401 API Authentication Errors
    - **Root Cause**: TranscriptionManager was initialized at app launch, capturing Soniox API key state at that time. If user saved the API key later (in TTS tab), TranscriptionManager wasn't updated.
    - **Solution**: Changed `sonioxAPI` from `let` to `var`, added `reloadSonioxAPIKey()` method, and call it on demand in `transcribeTrack()` before attempting upload
    - API key is now reloaded fresh from Keychain before each transcription attempt
    - Handles scenarios where user saves API key after app launch
**Next Steps**:
  1. Follow `local/stt-phase3-setup.md` Step 1-4 to add files to Xcode build target
  2. Run clean build to verify 0 errors
  3. Test: Save Soniox API key in TTS tab → try transcribing → should work without 401 errors
  4. End-to-end test: transcribe → view → search → retry
  5. Proceed to Phase 4 (polish & distribution)


### Feat: Collection Detail Auto Focus
**Status**: Done
**Doc**: `local/collection-auto-focus.md`  
**Notes**: Scroll the track list to the last played/current track whenever a collection detail view opens so users land on the in-progress item automatically.


### Bug: High Battery Consumption Investigation
**Status**: Done
**Doc**: `local/battery-performance-investigation.md`
**Notes**: Analyze energy usage during playback, downloads, and background tasks to see why the app drains more battery than expected. Capture findings + suggested fixes in the task doc.


### Bug: Favorite Tracks Disappear After App Restart
**Status**: ✅ FIXED
**Doc**: `local/bug-favorites-disappear-restart.md`
**Commits**:
  - `40b10f3` - fix(favorites): increase task priority for favorite status persistence
  - `cb1de32` - fix(favorites): correct GRDB optional value handling in verification
  - `7dbf0f9` - fix(favorites): update collection timestamp to prevent CloudKit overwrite
**Root Causes**:
1. Task priority was `.utility` (low), causing database writes to be deferred/cancelled on app close
2. Verification logging had double-optional handling bug (logging-only, data was saved correctly)
3. **CloudKit sync overwrote local favorites** because collection's `updatedAt` timestamp wasn't saved to GRDB
**Solutions**:
1. Increased Task priority to `.userInitiated` to ensure completion before app termination
2. Fixed verification code to use typed subscript for proper GRDB optional unwrapping
3. Added `updateCollectionTimestamp()` method and call it when favorites change to keep GRDB timestamps synchronized
**Testing**: Mark tracks as favorites, force kill app, restart, and verify favorites persist in FavoriteTracksView

### Bug: Transcript viewer blank until random success
**Status**: Done
**Doc**: `local/bug-transcript-viewer-random-empty.md`  
**Notes**: After a fresh launch, transcript sheets are empty for most tracks until one randomly succeeds; once one loads, all others work for that session. Need to ensure GRDB is initialized before transcript queries.


- Bug: AI selected model summary shows (null) and crashes refresh
  - Doc: `local/bug-ai-tab-model-summary-null.md`
