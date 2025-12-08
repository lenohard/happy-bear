# iOS Audiobook Player - Product Requirements & Architecture

This Reop is upload to Github: https://github.com/lenohard/happy-bear.
You can use deepwiki to query about detailas quickly of this repo using deepwiki tool.

Remeber use iphone 17 Pro simulator for building by default.


(Be aware that the folder ./local/ is not ignored by git for this repository.)
# Current Task

local/PROD.md:
@local/PROD.md


- Background audio + enhanced playback controls completed 2025-11-03

## Recent Progress (2025-11-28 – 2025-12-07)
- **RSS podcast collections (2025-12-07)**: Added `.rss` source support so users can import podcast feeds via a dedicated sheet, persist feed metadata/tracks, tag collections as podcast/rss, show antenna indicators in the Library + detail views, and refresh RSS collections to pull new episodes on demand. Parser errors/localization captured; see `local/rss-collection-support.md` + `local/new_xcstrings.md`.
- **Remote cover caching (2025-12-08)**: Library now prefetches every `.remote` cover (primarily RSS feeds) as soon as collections load/sync, saves them inside `CollectionCovers/`, and rewrites the model to `.image` so Library rows, detail headers, Now Playing, and backups show the art instantly even when offline. RSS imports also download the feed artwork immediately and persist it as a local cover so the very first render doesn't need to wait on AsyncImage.
- **Listening history & resume stability**: Playback collections now preload when the player starts so the Listening History surface can show context instantly, and a regression that dropped playback progress snapshots after relaunch is fixed (commits `65bd540`, `c5f982c`).
- **Collection refresh pipeline**: A dedicated collection import/refresh service coordinates Netdisk diffs, allowing the new "Refresh Collection" action (documented in `local/collection-refresh-implementation.md`) to reuse the same logic instead of duplicating folder traversal (commit `ae039f6`).
- **CollectionDetailView performance**: Removed the `visibleTrackIndices` tracker and redundant view work so long track lists scroll smoothly even after filter changes (commit `d4d0d9c`).
- **Date parsing reliability**: Ebook metadata now converts timestamps via `timeIntervalSinceReferenceDate`, and GRDB fetches correctly decode Date columns returned as native `Date` instances to prevent crashes when importing existing libraries (commits `6d08d73`, `9be5b34`).
- **Background DB/worker efficiency**: Consolidated playback/progress writes and throttled background processing queues to reduce redundant GRDB writes during cache downloads or transcription prep (commit `0f4f516`).

## Project Overview

An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

## Collaboration Notes (2025-11-17)
- When a task mainly requires configuration or mechanical asset edits (e.g., Xcode plist/localization wiring), prefer to document the exact steps and hand it to the user unless they explicitly ask for a full implementation. Always describe the workflow first so they can decide whether to run it themselves.
- Document those steps in `local/task-*.md` so future sessions can reuse them without re-reading diffs.

**Project Root**: `~/projects/audiobook-player`

## Recent Lessons

- **2025-12-05 – SwiftPM package product missing after DerivedData corruption**: If Xcode reports “Missing package product 'GRDB'” or fails to clone GRDB’s SQLiteCustom submodule, delete the entire `~/Library/Developer/Xcode/DerivedData/AudiobookPlayer-*` directory (including `SourcePackages`) and rerun `xcodebuild -resolvePackageDependencies -project AudiobookPlayer.xcodeproj`. This forces a clean SwiftPM checkout and fixes the broken submodule checkout.
- **2025-12-05 – iOS Background Job Limitations**: iOS suspends most operations when apps go to background. Polling loops (`Task.sleep`), WebSocket connections, and streaming all stop. Solutions: (1) For STT jobs with server-side processing: check status when app returns to foreground via `scenePhase` observer rather than continuous polling; (2) For TTS/AI: save partial results before backgrounding, show "interrupted" state on resume; (3) Soniox supports webhooks but requires a public endpoint - foreground-resume-check is simpler for mobile-only apps.
- **2025-12-05 – Job List Filtering Pattern**: When showing active vs history job lists, history should exclude jobs that appear in active list to prevent duplicates. Pattern: `let activeJobIds = Set(activeJobs.map(\.id)); historyJobs.filter { !activeJobIds.contains($0.id) }`.
- **2025-11-26 – Build Error: Duplicate var body declarations**: When fixing build errors, always check for duplicate `var body: some View {` declarations in SwiftUI View files. This is a common error pattern that causes "declaration is only valid at file scope" and "expected '}' in struct" errors. The fix is simple: remove the duplicate line. Related: also check for duplicate closing braces `}` that need to be removed after fixing the duplicate property. Quick fix workflow: `grep -n "var body: some View" filename.swift` to find all occurrences.
- **2025-11-26 – Xcode Build Lock**: If you get "database is locked" error during build, wait 2-3 seconds and retry. This happens when multiple build processes are running against the same derived data path. A simple `sleep 2 && xcodebuild...` resolves it.
- **2025-11-26 – Filter Build Output Efficiently**: Use `xcodebuild ... | grep -E "error:|warning:|BUILD"` to quickly see only the important lines instead of thousands of build steps. For quick error checks: `xcodebuild ... | grep "error:" | head -10` to get just the first 10 errors. For build status: `xcodebuild ... | tail -2` to see the final result. This saves significant time and tokens when diagnosing builds.
- **2025-11-27 – Swift Range Syntax**: When using `fractionLength` in `IntegerFormatStyle` or `FloatingPointFormatStyle`, use a `Range` (e.g., `0...1`) instead of comma-separated arguments. Incorrect syntax like `.fractionLength(0, 1)` causes "Extra argument in call" errors.
- **2025-11-27 – Duplicate File References**: If `xcodebuild` warns about "Skipping duplicate build file", check `project.pbxproj` for duplicate `PBXBuildFile` entries pointing to the same file reference. These can be safely removed to clean up the build.
- **2025-11-27 – Xcode Build Database Lock**: Persistent "database is locked" errors in `xcodebuild` often require killing all `xcodebuild` processes (`killall xcodebuild`) and/or clearing the `DerivedData` directory (`rm -rf ~/Library/Developer/Xcode/DerivedData/*`).
- **2025-11-27 – Swift Actor/Class Closure**: When editing large files (like `GRDBDatabaseManager.swift`), ensure that all methods and the class/actor itself are properly closed with `}`. Missing braces can cause confusing "Declaration is only valid at file scope" errors for extensions that follow.
- **2025-11-27 – Transcript sheet summary layout**: The track summary card now starts collapsed by default and the transcript sheet content lives inside a single `ScrollView`, which prevents the expanded card from overlapping the navigation bar on load while keeping the scroll-to-segment helpers working.

- **2025-11-20 – Mac Catalyst log spam**: Seeing `[API] cannot add handler to <N> from <M> – dropping` in the Xcode console is an Apple framework issue (Backboard/HID bridge) that appears after enabling Mac Catalyst; our code does not emit it. Treat it as harmless noise, hide it via scheme console filters or `OS_ACTIVITY_MODE=disable`, and keep Xcode/macOS updated until Apple removes the logging.
- **2025-11-20 – Track summary CTA + streaming stability**: Playing tab `TrackSummaryCard` now exposes a single header CTA that swaps between Generate/Regenerate, while `AIGenerationJobExecutor` buffers stream deltas on-actor so track summary jobs stop crashing with `EXC_BAD_ACCESS` when deltas arrive rapidly. Reuse `persistStreamDelta` whenever adding new streaming job types.
- **2025-11-18 – AI Gateway streaming + max token removal**: Chat/completions now streams by default (SSE via `URLSession.bytes`), stops sending `max_tokens` so each model uses its native cap, and automatically falls back to non-streaming if iOS reports `URLError.secureConnectionFailed` (TLS -1200/-9816). Fixed the endpoint path to always hit `/v1/chat/completions` when streaming.
- **2025-11-18 – AI tab tester feedback**: The AI tab's "Run Test" button now disables while streaming, shows a spinner, renders incremental chunks live, and flags when TLS issues force a non-streaming fallback so users stop re-tapping blindly.
- **2025-11-18 – Tap-to-dismiss keyboard**: `CreateCollectionView` and `AITabView` now attach a background `TapGesture` that calls `resignFirstResponder()` so iPhone users can hide the keyboard by tapping outside focused fields. Reuse this helper whenever we add new SwiftUI forms that rely on `Form`/`List`, since those containers don’t dismiss on their own.

- **2025-11-18 – Transcription cache parity & progress smoothing**: Transcription now reuses the playback cache for Baidu tracks (keyed by real fsId) and downloads via `AudioCacheDownloadManager`, so transcription is as fast as the playing card and updates the same cache entry. Added cache hit/miss logs. The sheet’s download progress bar now only advances during the download stage and no longer flickers when later stages update overall progress.

- **2025-11-17 – Transcription sheet progress + context**: The per-track transcription sheet now shows granular stages (download/upload/transcribe/process) with byte progress, and includes a user-editable context box that defaults to collection title/description + track name; context is sent via the Soniox `context` field. Progress UI polls active jobs to stay in sync with backend status.

- **2025-11-15 – Keychain access in Mac Catalyst DMG builds**: When packaging the Mac Catalyst build into an unsigned DMG for personal distribution, the app crashed with `Keychain error: 没有所需的授权`. The fix was to enable the **Keychain Sharing** capability so the Catalyst binary gets the required `keychain-access-groups` entitlement even when it is only signed with the free Personal Team certificate. Without that capability, importing backups that include credentials will fail on macOS because Keychain writes are denied.
  - DMG packaging script: `scripts/package-maccatalyst-dmg.sh`
  - Packaging guide: `DMG_PACKET_GUIDE.md`
  - Ensure entitlements: `AudiobookPlayer/AudiobookPlayer.entitlements` must include **Keychain Sharing** for Mac Catalyst builds to permit Keychain writes in unsigned DMG distribution scenarios.
- **2025-11-25 – Collection cover upload storage**: Uploaded cover photos are normalized (longest side capped at 900 px), re-encoded as JPEG (quality 0.9), and stored inside `Documents/CollectionCovers/<collectionID>-<timestamp>.jpg`; each update removes the prior file so a collection keeps only one image, and the entire directory is copied during export/import so backups include the art without letting oversized uploads bloat documents.
- **2025-12-02 – Backup & Restore contents**: The backup feature (`UserDataBackupManager`) exports the entire `library.sqlite` database snapshot, which includes **all** user data: collections, tracks, playback states, favorites, transcripts, transcript segments, transcription jobs, track summaries, **and listening statistics** (session-level data showing when and how long users listened to each track). The listening statistics are stored in the `listening_statistics` table within the same database. Optional credentials (AI Gateway, Soniox, Baidu OAuth tokens) are exported as separate JSON files only when the user opts in. See `local/export-import-user-data.md` for complete data inventory.
- **2025-11-10 – STT Simplification**: Removed `AudioFormatConverter.swift`, removed audio conversion logic from `TranscriptionManager.swift`, and removed `import AVFoundation` (Soniox supports common formats natively). Also fixed cache completion check: `getCachedAssetURL()` now returns a URL only when `metadata.cacheStatus == .complete`. Doc: `local/stt-integration.md`
- **2025-11-17 – Transcription prep visibility**: The TTS tab job list and Playing tab HUD now show download/upload preparation states by emitting transient `downloading`/`uploading` jobs before Soniox assigns a job ID. This keeps users informed while we fetch/cache the audio without persisting half-finished jobs.
- **2025-11-17 – AI transcript repair UX**: Transcript Viewer’s repair mode now defaults the low-confidence slider to 95%, surfaces icon-only toggles to show-only-selected or hide already AI-edited segments, and renders a sparkles badge next to the confidence label whenever a segment has `last_repair_model/at`. Logging also captures both the outbound prompt (with collection metadata) and the raw AI reply for easier debugging.
- **2025-12-02 – Transcript viewer auto-focus & repair mode removal**:
  - **Fixed nested ScrollView issue**: `ScrollViewReader.proxy.scrollTo()` couldn't find segment IDs that were nested inside a child `ScrollView`. Solution: removed the inner `ScrollView` wrapper from normal transcript view so segments are directly accessible to outer `ScrollViewReader`. This allows immediate scroll to the current playing segment when the sheet opens.
  - **Removed obsolete repair mode**: Completely removed 400+ lines of repair mode code including 8 `@State` variables (`isRepairMode`, `repairSelection`, `autoSelectThresholdPercent`, `showSelectedOnly`, `hideRepairedSegments`, `repairControlsExpanded`, `lastObservedRepairJobId`), repair UI methods, and toolbar section. User indicated this feature was no longer used.
  - **Optimized transcript layout**: Simplified `TranscriptSegmentRowView` to use single `HStack(alignment: .firstTextBaseline)` for time+confidence on one line with fixed 16pt height. Reduced all padding (12pt→6pt), inter-segment spacing (10pt→4pt), rounded corners (10pt→6pt), and line spacing (2pt→1pt).
  - **Also fixed**: Added `Equatable` conformance to `CollectionListBoundaryPreferenceData` struct in `CollectionDetailView.swift` to satisfy `onPreferenceChange` modifier requirement (pre-existing compilation blocker).
  - **Files**: TranscriptViewerSheet.swift, CollectionDetailView.swift
  - **Lesson**: Nested container views in SwiftUI affect view hierarchy and ID resolution for state-driven operations like `scrollTo()`. Always ensure views with `.id()` modifiers are direct children of containers that reference them via state.

### Build & Schemes

- Shared Xcode scheme `AudiobookPlayer.xcodeproj/xcshareddata/xcschemes/AudiobookPlayer.xcscheme` lives in the repo so `xcodebuild -scheme AudiobookPlayer` (CI, scripts, other agents) can resolve SwiftPM packages. Keep it under version control; removing it breaks command-line builds.
- **Build output quick filters**:

  - `xcodebuild ... | grep -i "build succeeded"`
  - `xcodebuild ... | grep -i error`
  - `xcodebuild ... | grep -i warning`

---

### App Icon Generation

**Script**: `./scripts/generate-app-icons.sh`

Generates all required iOS app icon sizes from a single source image.

**Usage**:

```bash
./scripts/generate-app-icons.sh <source-image-path>
```

**Example**:

```bash
./scripts/generate-app-icons.sh ~/Downloads/new-logo.png
```

**What it does**:

- Generates icons in sizes: 80, 120, 152, 167, 180, 1024 pixels
- Outputs to `AudiobookPlayer/Assets.xcassets/AppIcon.appiconset/`
- Uses macOS `sips` command for image resizing
- Provides git workflow instructions after completion

**After running**:

1. Review icons in Xcode
2. `git add AudiobookPlayer/Assets.xcassets/AppIcon.appiconset/*.png`
3. `git commit -m "Update app icon"`

---

## Current App Surface (2025-11)

### Tabs & Primary Screens

1. `Playing` (PlayingView in ContentView.swift) now opens by default when the app launches, renders the active/last-played `PlaybackSnapshot`, playback history feed, progress bars, and exposes cache settings via the toolbar sheet; it gracefully falls back to persisted states when nothing is actively playing.
2. `Library` (LibraryView.swift) shows the GRDB-backed collections list with quick-play buttons, duplicate-import detection, Baidu-only import menu, favorites shortcut, and inline error banner fed by `LibraryStore.lastError`.
3. `Smart` (`SmartView`) combines the former AI, TTS, and related automation controls into a single tab. It hosts the `AITabView`, `TTSTabView`, and any shared job indicators while keeping the icon-driven interface intact. The individual `*TabView` files still exist for UI composition, but this explanation clarifies they are no longer standalone tabs.
4. `Personal` (`PersonalView`) houses listening history, statistics placeholders, and exposes the original `SettingsTabView` sections (cache management, Baidu sources, etc.) so users can keep configuration controls together. The `SettingsTabView` file now renders inside this tab rather than representing a top-level tab itself.

### Supporting Workflows & Sheets

- `CollectionDetailView` + `FavoriteTracksView` provide track-level playback, favorites, and per-track resume states; both surfaces reuse the shared `AudioPlayerViewModel` for actions.
- `BaiduNetdiskBrowserView` (and its detail sheet) powers both the Settings tab (Baidu Sources section) and Collection import flows, including direct streaming via `TemporaryPlaybackContext`.
- `CreateCollectionView` + `CollectionBuilderViewModel` orchestrate pulling an entire Netdisk folder (metadata, tracks, checksums) into the local library and monitor background work.
- `CacheManagementView` (linked from Settings tab) lets users inspect cache path/size, tweak TTL (1–30 days, default 10), clear everything, or nuke the currently playing track.
- `TranscriptionProgressOverlay`, `TranscriptionSheet`, and `TranscriptViewerSheet` surface Soniox job state, retry actions, and finished transcripts without leaving the current screen.
- `SplashScreenView` briefly shows the AppLogo while `AudiobookPlayerApp` wires up all environment objects (player, library, Baidu auth, tab manager, AI gateway, transcription manager).
- `FloatingPlaybackBubbleView` + `FloatingPlaybackBubbleViewModel` provide an iOS AssistiveTouch-style floating bubble for quick playback control from any tab:
  - **Gestures**: Single tap toggles play/pause (debounced 0.35s to avoid double-tap conflicts); double tap opens Playing tab; long press shows context menu (hide for session, settings); drag repositions and snaps to nearest edge.
  - **Visuals**: 60×60pt circle with dark background, circular progress ring showing track position, play/pause icon, 1.15× scale animation on interaction, configurable opacity (Settings slider).
  - **Position persistence**: Normalized X/Y stored in `AppStorage` and restored on launch; clamped within safe area bounds.
  - **Visibility**: Shown when a track is loaded and `isEnabled` is true (Settings toggle); can be hidden per-session via long-press menu.
  - **Files**: `FloatingPlaybackBubbleView.swift`, `FloatingPlaybackBubbleViewModel.swift`
  - **Implementation note**: Uses `.position()` modifier (not `.offset()`) applied *after* gestures to ensure hit-testing works correctly across the entire bubble area. Uses `DragGesture(coordinateSpace: .global)` to prevent jitter during drag.
---

## Architecture Snapshot (2025-11)

### Core Stack

- SwiftUI + ObservableObject environment graph inside `AudiobookPlayerApp`; Combine is used sparingly (e.g., cache progress publishers) while async/await drives Baidu, Soniox, and AI Gateway requests.
- AVFoundation/AVPlayer power playback with background audio + `MPRemoteCommandCenter` hooks for lock-screen/Control Center transport controls; `NowPlaying` metadata is kept in sync inside `AudioPlayerViewModel`.
- Persistence lives in GRDB-backed SQLite (`GRDBDatabaseManager`, `DatabaseSchema`, `TranscriptionDatabaseSchema`); JSON file fallback (`LibraryPersistence`) and optional `CloudKitLibrarySync` keep collections portable.
- Secrets stay in Keychain stores (`KeychainBaiduOAuthTokenStore`, `KeychainAIGatewayAPIKeyStore`, `SonioxKeychainStore`), while Info.plist still contains legacy placeholders for Baidu/Soniox defaults.

### Modules & Responsibilities

- **App shell & DI**: `AudiobookPlayerApp` instantiates player, library, Baidu auth, tab manager, AI gateway, and transcription manager, injects them via `.environmentObject`, and shows `SplashScreenView` until ready.
- **Library & collections**: `LibraryStore` coordinates GRDB + CloudKit + JSON fallback, handles schema upgrades, provides duplicate-path detection, favorites, and `recordPlaybackProgress`. `CollectionDetailView`, `LibraryCollectionRow`, and `FavoriteToggleButton` consume its data.
- **Baidu OAuth + Netdisk**: `BaiduAuthViewModel` wraps `ASWebAuthenticationSession`-backed `BaiduOAuthService`, persists tokens, and exposes sign-in/out states. `BaiduNetdiskClient` lists/searches directories and produces signed download URLs; `BaiduNetdiskBrowserView` + `BaiduNetdiskBrowserViewModel` provide the UI, and `NetdiskEntryDetailSheet` lets users play or save folders.
- **Import pipeline**: `CreateCollectionView` uses `CollectionBuilderViewModel` to fetch folder metadata, build `AudiobookCollection`/`AudiobookTrack` models, and persist them; duplicate detection feeds back into `LibraryView` alerts.
- **Audio engine & cache**: `AudioPlayerViewModel` manages playlists, tokens, resume logic, remote commands, and background audio session. `TemporaryPlaybackContext` keeps direct-play sessions coherent, while `AudioCacheManager`, `AudioCacheDownloadManager`, and `CacheProgressTracker` track partial/complete downloads with a 2 GB cap + 10-day TTL (customizable via `CacheManagementView`).
- **UI tabs**: `ContentView` orchestrates a 5-tab `TabView`, shares selection state through `TabSelectionManager`, and wires `.badge(transcriptionManager.activeJobs.count)` on the TTS tab so long-running jobs remain visible.
- **AI Gateway**: `AIGatewayViewModel` talks to `AIGatewayClient` (`https://ai-gateway.vercel.sh/v1`), caches the preferred model id, exposes provider-grouped catalogs with collapsible state, refreshes credits, and runs diagnostics chat calls; the UI keeps the key field empty after save for security.
- **Speech-to-text / TTS tab**: `SonioxKeyViewModel` persists the API key, `TranscriptionManager` orchestrates upload → job creation → polling → transcript storage, and `TranscriptionJobManager`/`TranscriptionRetryManager` handle persistence + retries. UI surfaces job rows, sample tests, retry/cancel buttons, and opens `TranscriptViewerSheet` for finished transcripts.
- **Background processing**: `BackgroundTranscriptionManager` configures a background `URLSession` for long uploads, emitting Notifications for progress/completion. Audio caching/download tasks use `URLSessionDownloadTask` with resumable progress observers.
- **System integrations**: Info.plist enables `UIBackgroundModes=audio`, lock-screen controls, and entitlements for networking. App Intents scaffolding (`AudiobookCollectionEntity`, `PlayCollectionIntent`, etc. inside `AppIntents/`) is implemented but blocked on paid Apple Developer provisioning.

### Data Flow

- Baidu OAuth (`BaiduAuthViewModel`) → `BaiduNetdiskBrowserView` fetches folder contents → `CreateCollectionView` persists them through `LibraryStore`/GRDB and optional `CloudKitLibrarySync`.
- Library selections (`LibraryView`/`CollectionDetailView`) → `AudioPlayerViewModel` loads playlists + resume state → streaming URLs are minted by `BaiduNetdiskClient`, optionally cached via `AudioCacheManager`, and surfaced in `PlayingView`.
- Playback ticks call `recordPlaybackProgress`, which updates GRDB and keeps history/quick-play tiles accurate; cache/download progress flows to `CacheManagementView` and `PlayingView` cards through `CacheStatusSnapshot`.
- Any track can spawn a transcription job (`TranscriptionManager`), which uploads audio to Soniox, polls for completion, saves transcripts/segments in SQLite, and notifies the UI overlays + TTS tab badge.
- AI Gateway traffic is isolated: user-supplied keys unlock model catalogs/credits/chat endpoints without touching audiobook data, but reuse the Keychain convention for secret storage.

### Phase 1: Foundation (MVP)

- [x] Project setup with SwiftUI + AVFoundation
- [x] Baidu OAuth2 authentication flow (authorization code + token exchange skeleton)
- [x] Basic file listing from Baidu Cloud
- [x] Simple audio player with basic controls (play/pause/skip)
- [x] Playback progress tracking
- [x] Basic UI (now playing screen, library view)

### Phase 2: Core Features

- [x] Bookmarking/resuming playback position
- [] Bookmarking for Netdisk path
- [x] Local library management
- [ ] Metadata display (title, artist, duration)
- [x] Playlist/collection organization
- [x] Speed control (0.75x, 1x, 1.25x, 1.5x, etc.)
- [x] Seek bar with scrubbing

### Phase 3: Enhancement

- [x] Sleep timer
- [x] Offline download support (cache audio locally)
- [x] Search functionality
- [x] Custom sorting/filtering
- [ ] iCloud sync for progress across devices
- [x] Lock screen playback controls

---

## Technology Decisions

| Component         | Options                        | Recommendation    | Notes                                                                                |
| ----------------- | ------------------------------ | ----------------- | ------------------------------------------------------------------------------------ |
| UI Framework      | UIKit vs SwiftUI               | **SwiftUI**       | Easier to maintain, modern iOS standard                                              |
| Audio Framework   | AVFoundation vs MediaPlayer    | **AVFoundation**  | More control, better for custom UI                                                   |
| Database          | Core Data vs SwiftData vs GRDB | **GRDB + SQLite** | Handles library + transcription tables with JSON fallback and optional CloudKit sync |
| Networking        | URLSession vs Alamofire        | **URLSession**    | Built-in, sufficient for this use case                                               |
| Async Concurrency | Callbacks vs async/await       | **async/await**   | Modern Swift standard (iOS 13+)                                                      |

---

## Risk & Considerations

1. **Baidu API Rate Limiting**: Need to handle API rate limits gracefully
2. **Audio Streaming Reliability**: Handle network interruptions, buffering
3. **OAuth Token Refresh**: Implement automatic token refresh before expiry
4. **Battery & Data Usage**: Streaming can consume significant resources

---

## Xcode Project Tips

- **Localization Resource Handling (no pbxproj script edits)**: Generate resource files (`.lproj` / `.strings` / `.xcassets`) via scripts, then add them through Xcode UI (Build Phases → Copy Bundle Resources). Do **not** modify `project.pbxproj` programmatically.
5. **Privacy**: Securely store Baidu credentials in Keychain
6. **App Store Policy**: Verify app complies with Apple's guidelines for cloud storage integration

---

## Progress Tracking

### Session: 2025-11-05 (App Intents Investigation & WIP)
**Siri/App Intents Exploration** 🔍

- [x] Analyzed App Intents architecture and implementation plan
- [x] Created complete App Intents infrastructure (Phase 1 & 2):
  - AudiobookCollectionEntity, AudiobookCollectionQuery, PlayCollectionIntent, AudiobookShortcuts
  - IntentPlaybackController, LibrarySnapshotStore, AudiobookCollectionSummary
- [x] Added 13 Siri localization keys (English + Chinese) to Localizable.xcstrings
- [x] Upgraded iOS deployment target from 16.0 → 17.0 (App Intents requirement)
- [x] Configured entitlements with `com.apple.developer.appintents` flag
- ❌ **BLOCKED**: Free/Team Apple Developer accounts cannot provision App Intents entitlements
  - Error: "iOS Team Provisioning Profile doesn't include the com.apple.developer.appintents entitlement"
  - Only paid ($99/year) Apple Developer accounts can create provisioning profiles with App Intents support
  - Solution: Saved all work in `feature/siri-control-wip` branch (commit: `ba67470`)
  - Action: When account upgraded to paid, restore from WIP branch and proceed with Phase 4 device testing

**Important Lesson - Xcode Project File Handling**:

- ❌ DO NOT attempt to edit `project.pbxproj` via bash/Python scripts
- ✅ Instead: Generate content files (`.strings`, assets, etc.) programmatically, then let user manually add to Xcode via UI
- ✅ This approach is more reliable and avoids pbxproj corruption
- For localization tasks: Generate `.lproj` directories + `.strings` files, then ask user to add via Xcode UI

### Session: 2025-11-03

- [x] Enabled background audio playback via Info.plist `UIBackgroundModes=audio` and refined audio session configuration.
- [x] Hardened now playing commands to resume idle playback, improve previous/next fallbacks, and keep Baidu token refresh handling.
- [x] Surfaced saved track progress with progress bars, timestamps, and percent labels derived from `playbackStates`.
- [x] Removed collection-level "Play All" in favor of per-track controls and new library quick-play buttons that resume from stored positions.
- [x] Added dedicated Playing tab that restores the active or last-played collection with persisted playback state and shared transport controls.

### Session: 2025-02-11

- [x] Initialized `AudiobookPlayer.xcodeproj` with SwiftUI target and AVFoundation dependency
- [x] Added starter `AudioPlayerViewModel` and `ContentView` scaffolding
- [x] Documented run instructions in README

# Notes

1. Don't run to run the simulator, leave the test to me, but you should use cmd to build project to see the warnings and errors and try to fix them.
2. Do not try to add the files under local/ into git repo commit. they should be ignored.

3. **Filtering Xcode Build Output**: Xcode build output can be very large (thousands of lines). Use grep to filter and check for specific conditions:

   - **Check for errors**: `xcodebuild ... | grep -i error`
   - **Check for warnings**: `xcodebuild ... | grep -i warning`
   - **Check for success**: `xcodebuild ... | grep -i "build succeeded"`
   - **See last lines**: `xcodebuild ... | tail -n 20`
   - This saves tokens and makes build verification more efficient

4. **⚠️ CRITICAL - Localizable.xcstrings File Corruption Protection**:
   - **PROBLEM**: The `AudiobookPlayer/Localizable.xcstrings` file is prone to corruption when edited by multiple agents or tools
   - **Common Issues**:
     - File gets converted to binary plist format (breaks Xcode build)
     - Missing required `"version": "1.0"` field at root level
   - **⚠️ BEFORE EDITING Localizable.xcstrings**:
     1. **Always backup first**: `cp AudiobookPlayer/Localizable.xcstrings AudiobookPlayer/Localizable.xcstrings.backup-$(date +%Y%m%d-%H%M%S)`
     2. **Check file type**: Must be JSON, not binary plist - `file AudiobookPlayer/Localizable.xcstrings` should return "JSON data"
     3. **Verify structure**: Must have `{"sourceLanguage": "en", "version": "1.0", "strings": {...}}`
   - **IF FILE IS CORRUPTED**:
     1. Run `scripts/add_ai_tab_keys.py` to restore AI tab keys
     2. Add missing `"version": "1.0"` field if needed
     3. If file is binary plist, restore from git: `git checkout HEAD -- AudiobookPlayer/Localizable.xcstrings` then re-run step 1 & 2

5. **Xcode Project File Editing**: Never attempt to programmatically edit `project.pbxproj`. Instead:
   - Generate required resource files (`.strings`, `.xcassets`, etc.) using scripts
   - Create necessary directory structure (`*.lproj`, etc.)
   - Ask user to manually add files/folders to Xcode project via UI (Build Phases > Copy Bundle Resources, etc.)
   - User then builds and tests in Xcode
     This prevents pbxproj corruption and ensures proper project configuration.

6. **UI Localization Best Practices**: When writing UI code, always use localization keys for multi-language support:
   - ✅ **DO**: Use `Text("search_files")` with corresponding entries in `Localizable.xcstrings`
   - ✅ **DO**: Use `Label("Current Path", systemImage: "folder")` where system images are universal
   - ❌ **DON'T**: Use hardcoded strings like `Text("Search files")` directly in UI code
   - **Example**:

     ```swift
     // Good - uses localization key
     Text("search_files_prompt")

     // Add to Localizable.xcstrings:
     // "search_files_prompt": "Search files" (English)
     // "search_files_prompt": "搜索文件" (Chinese)
     ```

7. **App Intents & Siri Support - Requires Paid Developer Account**:
   - ❌ **FREE accounts cannot use App Intents**: Free and Team provisioning profiles lack `com.apple.developer.appintents` entitlement support
   - ❌ **Paid accounts only**: Only Apple Developer Program members ($99/year) can create App Intents-enabled provisioning profiles
   - ✅ **Workaround**: Save complete implementation in WIP branch, restore when account is upgraded
   - ✅ **All other features** (background audio, cache, playback controls, lock screen) work fine on free accounts
   - **Lesson**: Always verify account limitations before implementing platform-specific features. App Intents was fully architected before discovering the blocker.

8. **UI Button Design Pattern - Intuitive Refresh Buttons**:
   - ✅ **Use icon-only buttons for intuitive actions**: Refresh buttons (↻), close buttons (✕), etc. don't need text labels
   - ✅ **Design**: `Button { ... } label: { Image(systemName: "arrow.clockwise") }`
   - ✅ **Style**: Use `.buttonStyle(.bordered)` + `.controlSize(.small)` for consistency
   - ✅ **Placement**: Pair with content (e.g., refresh button next to quota display)
   - **Guideline**: Don't add labels to buttons whose function is immediately obvious from the icon
   - **Example**: AI tab refresh buttons for models and credits use icon-only design

10. **Simple Fixes Don't Require Testing**:
- For obvious, low-risk changes, skip the build/test step to save time and tokens
- ✅ **Examples of simple fixes**: Removing debug logs, fixing typos in comments, code formatting, string updates
- ❌ **Still needs testing**: Logic changes, API modifications, new features, refactoring
- **Workflow**: Make the change → commit directly → move on
- **Rationale**: Build verification takes time and tokens; trust that integration tests will catch regressions for complex changes
- **Example**: Removing `print()` statements doesn't need a full Xcode build cycle

## Database Reference (STT & Library)

- **Main Database**: `~/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite`
- **Database Type**: SQLite with GRDB ORM
- **Key Tables**: `transcripts`, `transcript_segments`, `transcription_jobs`, `collections`, `tracks`, `playback_states`
- **Documentation**: See `local/database-reference-debug.md` for full schema, queries, and debug commands
- **Current State (2025-11-09)**: 1 transcript with 16 segments, 4250+ chars of text, marked as "complete"
- **Known Issue**: Transcript data is saved in DB but TranscriptViewerSheet shows blank (investigate state refresh)
- UI Localization Best Practices: When writing UI code, always use localization keys for multi-language support. Use Text("search_files") with corresponding entries in Localizable.xcstrings, not hardcoded strings like Text("Search files"). Process: 1) Use descriptive localization keys in code, 2) Add entries to Localizable.xcstrings, 3) Generate .strings files via generate_strings.py, 4) User manually adds to Xcode project, 5) Test in both English and Chinese device settings.

1. if it's too hard for you to edit xcstrings, you can Leave the localizable.xcstrings for me, you just provide me with the entrys in a local/new_xcstrings.md
   I will finish it manully in xcode. this file is too large x000+ lines.
2. Try to avoid to use text labels , when the icon is intuitvie enough.
