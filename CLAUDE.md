# iOS Audiobook Player - Product Requirements & Architecture

This Reop is upload to Github: https://github.com/lenohard/happy-bear.
You can use deepwiki to query about detailas quickly of this repo using deepwiki tool.

Remeber use iphone 17 Pro simulator for building by default.

# Current Task

local/PROD.md:
@local/PROD.md

- Background audio + enhanced playback controls completed 2025-11-03

## Project Overview

An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

**Project Root**: `~/projects/audiobook-player`

## Recent Lessons

- **2025-11-15 – Keychain access in Mac Catalyst DMG builds**: When packaging the Mac Catalyst build into an unsigned DMG for personal distribution, the app crashed with `Keychain error: 没有所需的授权`. The fix was to enable the **Keychain Sharing** capability so the Catalyst binary gets the required `keychain-access-groups` entitlement even when it is only signed with the free Personal Team certificate. Without that capability, importing backups that include credentials will fail on macOS because Keychain writes are denied.
  - DMG packaging script: `scripts/package-maccatalyst-dmg.sh`
  - Packaging guide: `DMG_PACKET_GUIDE.md`
  - Ensure entitlements: `AudiobookPlayer/AudiobookPlayer.entitlements` must include **Keychain Sharing** for Mac Catalyst builds to permit Keychain writes in unsigned DMG distribution scenarios.
- **2025-11-10 – STT Simplification**: Removed `AudioFormatConverter.swift`, removed audio conversion logic from `TranscriptionManager.swift`, and removed `import AVFoundation` (Soniox supports common formats natively). Also fixed cache completion check: `getCachedAssetURL()` now returns a URL only when `metadata.cacheStatus == .complete`. Doc: `local/stt-integration.md`
- **2025-11-17 – Transcription prep visibility**: The TTS tab job list and Playing tab HUD now show download/upload preparation states by emitting transient `downloading`/`uploading` jobs before Soniox assigns a job ID. This keeps users informed while we fetch/cache the audio without persisting half-finished jobs.
- **2025-11-17 – AI transcript repair UX**: Transcript Viewer’s repair mode now defaults the low-confidence slider to 95%, surfaces icon-only toggles to show-only-selected or hide already AI-edited segments, and renders a sparkles badge next to the confidence label whenever a segment has `last_repair_model/at`. Logging also captures both the outbound prompt (with collection metadata) and the raw AI reply for easier debugging.

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

### Tabs & Primary Screens (5 tabs)

1. `Playing` (PlayingView in ContentView.swift) now opens by default when the app launches, renders the active/last-played `PlaybackSnapshot`, playback history feed, progress bars, and exposes cache settings via the toolbar sheet; it gracefully falls back to persisted states when nothing is actively playing.
2. `Library` (LibraryView.swift) shows the GRDB-backed collections list with quick-play buttons, duplicate-import detection, Baidu-only import menu, favorites shortcut, and inline error banner fed by `LibraryStore.lastError`.
3. `AI` (AITabView.swift) manages the AI Gateway keychain secret, fetches credits/model catalogs from `AIGatewayClient`, lets users search/collapse provider groups, and runs quick chat/generation lookups for validation.
4. `TTS` (TTSTabView embedded in AITabView.swift) is the Soniox/STT control room: users store their key, run a sample transcription, monitor active/recent jobs, jump into `TranscriptionSheet`/`TranscriptViewerSheet`, and the tab badge reflects `transcriptionManager.activeJobs`.
5. `Settings` (SettingsTabView.swift) consolidates app configuration:
   - **Cache Management**: Inspect cache path/size, tweak TTL (1–30 days, default 10), clear everything, or nuke the currently playing track.
   - **Baidu Sources**: Auth state, Netdisk browser (`BaiduNetdiskBrowserView` + sheet detail), direct-play for supported audio, and "save parent folder into library" flow; local files stubbed for future expansion.

### Supporting Workflows & Sheets

- `CollectionDetailView` + `FavoriteTracksView` provide track-level playback, favorites, and per-track resume states; both surfaces reuse the shared `AudioPlayerViewModel` for actions.
- `BaiduNetdiskBrowserView` (and its detail sheet) powers both the Settings tab (Baidu Sources section) and Collection import flows, including direct streaming via `TemporaryPlaybackContext`.
- `CreateCollectionView` + `CollectionBuilderViewModel` orchestrate pulling an entire Netdisk folder (metadata, tracks, checksums) into the local library and monitor background work.
- `CacheManagementView` (linked from Settings tab) lets users inspect cache path/size, tweak TTL (1–30 days, default 10), clear everything, or nuke the currently playing track.
- `TranscriptionProgressOverlay`, `TranscriptionSheet`, and `TranscriptViewerSheet` surface Soniox job state, retry actions, and finished transcripts without leaving the current screen.
- `SplashScreenView` briefly shows the AppLogo while `AudiobookPlayerApp` wires up all environment objects (player, library, Baidu auth, tab manager, AI gateway, transcription manager).

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
- [ ] Speed control (0.75x, 1x, 1.25x, 1.5x, etc.)
- [x] Seek bar with scrubbing

### Phase 3: Enhancement

- [ ] Sleep timer
- [x] Offline download support (cache audio locally)
- [ ] Search functionality
- [ ] Custom sorting/filtering
- [ ] iCloud sync for progress across devices
- [ ] Dark mode support
- [x] Lock screen playback controls

### Phase 4: Polish & Distribution

- [ ] Unit tests
- [ ] UI/UX refinement
- [ ] Performance optimization
- [ ] App Store submission preparation
- [ ] Beta testing

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
- **Localization workflow**: Provide only the key entries in `local/new_xcstrings.md`; manually merge into `AudiobookPlayer/Localizable.xcstrings` within Xcode. Validate structure and keys using `scripts/validate_localization.sh`, and follow the Localizable.xcstrings corruption protection notes.

5. **Privacy**: Securely store Baidu credentials in Keychain
6. **App Store Policy**: Verify app complies with Apple's guidelines for cloud storage integration

---

## Progress Tracking

### Session: 2025-11-10 (Tab Consolidation)

**Tab Layout Refactoring** 🎨

- [x] Consolidated tab navigation from 6 tabs → 5 tabs
  - Removed independent `Sources` tab
  - Moved Baidu netdisk browser and auth controls into `Settings` tab as "Baidu Sources" section
  - New tab order: Library → Playing → AI → TTS → Settings
- [x] Updated tab enum in `TabSelectionManager` (ContentView.swift)
- [x] Integrated Baidu browser UI into `SettingsTabView.swift`
- [x] Updated project memory documentation
- ✅ Build verified with 0 errors
- **Rationale**: Space optimization - iOS tab bar max 5 tabs before overflow; consolidates related settings (cache + sources) into single tab
- **Files Changed**: ContentView.swift, SettingsTabView.swift
- **Commit**: `ec437c2`

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

### Session: 2025-11-02

- [x] Project directory created
- [x] PROD.md initialized with architecture & planning
- [x] Integrated Baidu OAuth sign-in UI backed by `ASWebAuthenticationSession` and token exchange service
- [x] Added Info.plist placeholders for Baidu credentials and custom URL scheme registration
- [x] Verified simulator build locally via `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -destination 'generic/platform=iOS Simulator' build`

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

9. **STT Simplification - Removed Audio Format Conversion (2025-11-10)**:

   - **Problem**: AudioFormatConverter added unnecessary complexity - Soniox supports all common audio formats natively
   - **Solution**: Completely removed audio format conversion code
     - Deleted `AudioFormatConverter.swift` (115 lines)
     - Removed conversion logic from `TranscriptionManager.swift`
     - Removed `import AVFoundation` (no longer needed)
   - **Impact**: Cleaner codebase, faster transcription, no quality loss from re-encoding
   - **Also Fixed**: Cache completion check - `getCachedAssetURL()` now verifies `metadata.cacheStatus == .complete` before returning URL
   - **Doc**: `local/stt-integration.md` Session 2025-11-10

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

## Qwen Added Memories

- UI Localization Best Practices: When writing UI code, always use localization keys for multi-language support. Use Text("search_files") with corresponding entries in Localizable.xcstrings, not hardcoded strings like Text("Search files"). Process: 1) Use descriptive localization keys in code, 2) Add entries to Localizable.xcstrings, 3) Generate .strings files via generate_strings.py, 4) User manually adds to Xcode project, 5) Test in both English and Chinese device settings.

!!!!

1. Leave the localizable.xcstrings for me, you just provide me with the entrys in a local/new_xcstrings.md
   I will finish it manully in xcode. this file is too large 3000+ lines.
2. Try to avoid to use text labels , when the icon is intuitvie enough.
