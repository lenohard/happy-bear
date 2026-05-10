# iOS Audiobook Player - Product Requirements & Architecture

**Repo**: https://github.com/lenohard/happy-bear  
BaiduNetdisk Doc: https://pan.baidu.com/union/doc/pksg0s9ns
**Tools**: Use `deepwiki` for quick repo details.  
**Build Target**: iPhone 17 Pro simulator.  
**Note**: The `./local/` folder is **NOT** ignored by git for this repository.

## Recent Progress (Dec 2025)
- **Global Search (May 2026)**: Added `.searchable` to `LibraryView` for searching across all collections (title/author) and tracks (displayName). Results grouped into "Collections" and "Tracks" sections using existing `CollectionListRow` and `FavoriteTrackRow` views. Search is inline — replaces the main content when active. Key lesson: `AudiobookCollection` uses `title` while `AudiobookTrack` uses `displayName` (no `title` property). Uploaded as version 0.3.2 (build 19) to TestFlight.
- **Remote STT Fix (Apr 2026)**: Fixed broken remote STT server mode. Tailscale Serve was misconfigured to proxy `https://mathemac-mini.tailb0587a.ts.net` → `http://127.0.0.1:18789` (a Node.js app) instead of the FastAPI server on port 8081. Fixed with `tailscale serve reset && tailscale serve --bg --https=443 http://127.0.0.1:8081`. After fix, iOS client successfully connects and remote STT jobs run end-to-end. Note: Baidu download URLs can expire — if job fails with "write operation timed out", retry with a fresh session.
- **Chapter Support (Feb 2026)**: Added chapter support for audiobook collections. When importing a folder with subfolders, each subfolder becomes a chapter. Tracks in subfolders get the parent folder name as chapter. Collection detail view automatically groups tracks by chapter with headers showing folder icon, chapter name, and track count. Tracks without chapter appear at the end labeled as "Other". Fully backward compatible - collections without chapters display as flat list. Implementation includes: `chapter` property in `AudiobookTrack`, database migration, `extractChapter()` in CollectionBuilderViewModel, `ChapterGroup` struct and `chapterGroups` in CollectionDetailViewModel, UI grouping in CollectionDetailView.

- **VLC Audio-Only Playback (Dec 20)**: Implemented VLC audio-only support for MKV/WebM files. When playing MKV/WebM, VLC handles audio without showing video UI (treating them like regular audio files). Updated `play(track:)` to call `startVLCAudioPlayback()` instead of bailing out. All playback controls (play/pause, seek, skip, speed, sleep timer) now work with VLC audio. Added `usingVLCAudio` flag, `vlcTimeUpdateTimer` (250ms polling), and time/state tracking. Fixed VLC drawable operations with main thread dispatch (resolves "Modifying properties off main thread" crashes). Simplified `handlePlayButtonPress()` to always call `togglePlayback()`.
- **VLC Threading Fix (Dec 20)**: Fixed VLC OpenGL crashes by wrapping all `player.drawable` operations in main thread checks. VLC requires drawable operations on main thread for OpenGL initialization/teardown. Added checks to `VLCHostView.layoutSubviews()`, `updateUIView()`, `setupPlayer()`, and `cleanup()` with `Thread.isMainThread` guards and `DispatchQueue.main.async` fallbacks.
- **VLC Playback Controls Fix (Dec 20)**: Fixed four interrelated VLC playback issues: (1) Play button now calls `openVideoPlayer(for:)` for VLC-only tracks instead of `togglePlayback()`; (2) Added `toggleVideoPlayback()` method for controlling minimized VLC sessions from Playing tab; (3) Fixed black screen on reopening VLC sheet by creating `VLCHostView` that rebinds drawable in `layoutSubviews()` and adds binding check in `updateUIView()`; (4) Native AVPlayer PiP already delegates to sheet via `isPresented` binding. Added `VideoPresentationMode` enum (hidden/fullscreen/mini) and `setVideoPresentationMode()` to track video state.
- **VLC Video Support (Dec 18)**: Integrated MobileVLCKit v3.7.0 via CocoaPods for MKV/WebM playback. Added `VLCVideoPlayerView` wrapper with custom controls. Format detection blocks AVPlayer from attempting unsupported formats.
- **MVVM & Performance (Dec 12-15)**: Refactored `CollectionDetailView` to MVVM to fix actor isolation. Implemented background thumbnail generation (320px) + NSCache for smooth library scrolling. Moved heavy model grouping to background tasks.
- **RSS Support (Dec 7)**: Added `.rss` source support, feed import, and remote cover caching. Covers are now prefetched and stored locally.
- **Playback Features (Dec 8)**: Added Random Play (shuffle), fixed Play button token guard (offline play), and improved Floating Bubble visibility using a separate `UIWindow` (level `.alert + 1`).
- **Infrastructure**: Consolidated background DB writes, improved date parsing reliability, and fixed listening history resume stability.
- **Remote Jobs UI (Dec 29)**: Remote STT jobs are stored locally (prefixed `remote:`) and shown in the Jobs screen. Smart tab badges now separate local vs remote counts: Jobs badge shows remote STT/AI running jobs; STT and AI badges only show local jobs. AI remote jobs are detected via `AIGenerationJob.metadata.extras["remote_job_id"]` and are excluded from the local AI jobs list.

## Project Overview
An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

## Collaboration Notes
- **Task Docs**: Document complex config/asset steps in `local/*.md` rather than executing them fully unless requested.
- **State**: Use `local/` for task documentation to preserve context across sessions.

## Key Lessons & Patterns
### Architecture & Performance
- **Actor Isolation**: Call actor-isolated methods (GRDB) from `async` ViewModel methods. Avoid synchronous wrappers around actor calls.
- **MVVM**: Use dedicated ViewModels for complex views (e.g., `CollectionDetailView`) to separate logic and clarify isolation boundaries.
- **Scroll Performance**: Preload assets (images) to NSCache in background (`Task.detached`). View `onAppear` should check cache synchronously.
- **High-Frequency State**: Don't publish playback ticks (`currentTime`) from main `EnvironmentObject`. Use a small, dedicated `ObservableObject` (`PlaybackClock`) for timeline views to avoid massive re-renders.
- **Background Tasks**: iOS suspends polling/sockets in background. Check job status on foreground resume (`scenePhase`) instead of continuous polling.
- **Database Sync Strategy**: Prefer simple DB-file sync by placing `library.sqlite` inside iCloud Drive / app container location included in Apple sync between Mac and iPhone. Do not build CloudKit or other complex record-level sync unless requirements change.
- **Backup/Restore Coverage**: Backup exports the full `library.sqlite`, so collection folders + archived state are included automatically. Restore replaces the DB and runs migrations, so older backups upgrade to the new schema.
- **Data Model Property Names**: `AudiobookCollection` uses **`title`** for its name, while `AudiobookTrack` has **no `title`** property — its display name is **`displayName`**. When filtering/searching across both collections and tracks, be careful not to mix these up. Use `localizedCaseInsensitiveContains` for search matching.

### SwiftUI & UI
- **Overlays vs Sheets**: `overlay()` doesn't render above sheets. For persistent UI (bubbles), use a separate `UIWindow` with `PassThroughWindow`.
- **Nested ScrollViews**: Avoid nesting `ScrollView` inside another if using `ScrollViewReader.scrollTo()`.
- **Swipe Actions**: Use `.labelStyle(.iconOnly)` for swipe buttons to ensure centering.

### Baidu & Networking
- **WebSocket Handshake**: Always wait for `didOpenWithProtocol`. Use fresh `URLSession` per request for stability.
- **SSML/XML**: Always escape text input (especially `&`, `<`, `>`) before embedding in SSML. Malformed XML causes the server to drop the connection immediately, leading to confusing "Socket not connected" errors.
- **Collection Refresh**: Relies on fixed folder paths. Renaming the source folder in Netdisk breaks refresh; adding files to the folder is supported.
- **Streaming**: Baidu Netdisk does not natively support WebM streaming.

### Video Playback & Format Support
- **MKV/WebM Audio-Only**: MKV/WebM files are played as audio-only (no video UI). VLC is used as an audio engine via `startVLCAudioPlayback()`. All standard playback controls work (play/pause, seek, skip, speed, sleep timer, remote commands). Time updates polled every 250ms via `vlcTimeUpdateTimer`. Track auto-advances when finished.
- **MP4/MOV Support**: MP4/MOV files support both audio-only playback and optional full-screen video. Click play for audio. Optional video sheet available via `openVideoPlayer()`.
- **Format Detection**: Use `PlayableMediaFormat.requiresVLC()` to check if MKV/WebM. Always block unsupported formats from AVPlayer.
- **VLC Audio Implementation**: `usingVLCAudio` flag tracks VLC audio mode. `startVLCAudioPlayback()` sets up resume position, duration, and starts polling. `handleVLCTrackEnded()` detects end-of-track and triggers `playNextTrack()` or respects sleep timer.
- **VLC Threading**: All `player.drawable` operations require main thread dispatch. `VLCHostView.layoutSubviews()`, `updateUIView()`, `setupPlayer()`, and `cleanup()` check `Thread.isMainThread` and use `DispatchQueue.main.async` when needed. Fixes "Modifying properties off main thread" crashes from VLC's OpenGL initialization.
- **Playback Controls**: `handlePlayPauseRequest()`, `seek()`, and `skip()` check `usingVLCAudio` and delegate to VLC methods when active. Maintains unified interface across audio and VLC playback.
- **VLC Drawable Rebinding**: When reopening minimized VLC session, drawable must be rebound. `VLCHostView` stores weak player reference and rebinds in `layoutSubviews()`. `updateUIView()` also checks/rebinds drawable.
- **Video Presentation State**: `VideoPresentationMode` enum tracks state (hidden/fullscreen/mini) for MP4/MOV video sheets. Managed via `setVideoPresentationMode()`.
- **PiP Restore**: `AVPlayerViewControllerRepresentable` delegates to sheet via `restoreUserInterfaceForPictureInPictureWithCompletionHandler`, reopening sheet when restoring from PiP.

### Build & Xcode
- **Database Locked**: If `xcodebuild` fails with "database is locked", wait/retry or run `killall xcodebuild` and clear DerivedData.
- **Duplicate Body**: "Declaration only valid at file scope" often means a duplicate `var body: some View` line.
- **Catalyst**: Enable **Keychain Sharing** capability for Mac Catalyst builds to allow Keychain writes in unsigned DMGs.
- **Build Filters**: Use `xcodebuild ... | grep -E "error:|BUILD"` to reduce noise.
- **CocoaPods Workspace**: Always open `.xcworkspace` (not `.xcodeproj`) when CocoaPods dependencies are present. Run `pod install` after Podfile changes. Use `pod deintegrate && pod install` to reset if framework linking issues occur.
- Beacues Current there are many warnings, so then you build to fix the errors filter out the warnning ones by default !

### Chapter Support
- **Chapter Detection**: Use immediate parent folder name as chapter. Files directly under root folder have no chapter (nil).
- **Chapter Grouping UI**: Use `chapterGroups` computed property in ViewModel to group tracks. Check `hasChapters` first to determine rendering path.
- **Backward Compatibility**: Chapter is optional. Old data with nil chapter displays as before (flat list).
- **Data Model**: Chapter stored in database as optional TEXT column with migration for existing databases.

## Main Views & Workflows

### App Structure (ContentView.swift)
- **TabSelectionManager**: Manages 4 tabs (Library, Playing, Smart, Personal) + navigation state
- **PlayingView** (embedded): Main playback interface
  - Live playback card: cover art, title, timeline slider, play/pause/skip controls
  - Resume card: shows last played when nothing active
  - Listening history: recent playbacks from all collections
  - Track summary card: AI-generated summaries with seek-to-section
  - Sleep timer: end-of-track or timed (5-60 min)
  - Playback speed: 0.5x-3.0x presets
  - Shuffle toggle (per-collection), download button, video player sheet
- **PlaybackClock**: Dedicated ObservableObject for high-frequency ticks (avoids re-rendering entire view)

### Library Management

**LibraryView.swift** - Collection list & import hub
- Collection rows: cover art, title, author, track count, last updated, quick-play button
- Import menu: Baidu Netdisk (folder browser), Ebook (.epub), RSS Feed (URL)
- Swipe-to-delete, duplicate import detection, Favorite Tracks nav link

**CollectionDetailView.swift + CollectionDetailViewModel.swift** (MVVM)
- **Paging**: Auto-activates for >1000 tracks (500/page, on-demand loading)
- **Filters**: All, Transcribed, Unplayed, Summarized, Played
- **Sort**: Track Number, Title, Pub Date (Asc/Desc)
- **Track Row**: Play/pause, prev/next, favorite, transcript badge, summary badge
- **Swipe Actions**: Rename, Delete, View/Delete Transcript, Transcribe
- **Collection Actions**: Add tracks, Refresh (scan source), Batch rename, Edit details, Update cover
- **Auto-focus**: Scrolls to currently playing or last played track
- **Performance**: Background sort/filter, debounced search (300ms), batched DB status queries

**CreateCollectionView.swift + CollectionBuilderViewModel.swift** - Import flow
- States: Idle → Loading (progress) → Ready (review) → Failed
- Review: Edit title/description, select tracks, toggle "Music Collection", save

### Playback System

**AudioPlayerViewModel.swift** - Core playback engine
- AVPlayer management, playback state (`isPlaying`, `currentTime`, `duration`, `playbackRate`)
- Controls: play/pause, seek, skip ±15/30s, prev/next track, speed 0.5x-3.0x, shuffle
- Sleep timer: Off, Time-based, End-of-track
- Cache integration: checks `AudioCacheManager`, streams if not cached
- VLC support: `currentVLCStreamingURL` property for MKV/WebM streams, format detection blocks AVPlayer
- Remote commands: lock screen/control center (play, skip, now playing info, favorite state)
- Session tracking: auto-saves progress, resume from last position

**VLCVideoPlayerView.swift** - MKV/WebM video playback
- SwiftUI wrapper for VLCMediaPlayer with UIViewRepresentable pattern
- Coordinator manages VLC player lifecycle, delegates for state/time updates
- Full video controls: play/pause, seek slider (with time display), skip ±15s, draggable overlay

**VLCVideoPlayerSheet.swift** - Video player sheet interface
- Fullscreen video with tap-to-toggle overlay controls
- Top bar: close button, video title
- Bottom bar: progress slider, current/total time, playback buttons
- Black background, gradient overlays for readability

**FloatingPlaybackBubbleView.swift** - Global mini-player
- Separate UIWindow (level `.alert + 1`) for persistent overlay
- Draggable, shows mini cover + title + play/pause, tap switches to Playing tab

### AI & Transcription

**SmartView.swift** - Hub with nav links to:
- AI Tab: LLM chat, track summaries, generation jobs
- STT (Soniox): Speech-to-text jobs
- TTS (Edge): Text-to-speech audio generation
- Badge indicators for active job counts

**TranscriptionManager.swift** - Soniox STT integration
- Workflow: Upload audio → Create job → Poll status (2s interval, 1hr max) → Store transcript
- Job states: Queued, Uploading, Transcribing, Processing, Complete, Failed
- Stores transcripts in GRDB with segments and metadata
- **Remote Jobs**: Remote STT runs via remote server when enabled; jobs are stored locally with `sonioxJobId` prefixed by `remote:`. On app foreground, remote-running jobs resume polling via the remote API until success/failure.

**AIGatewayViewModel.swift** - LLM integration
- API key management (Keychain), model selection, credits tracking
- Chat interface, track summary generation (via AIGenerationManager)

### Personal & Settings

**PersonalView.swift** - User profile container
- Listening History sheet, Listening Statistics, Settings link

**SettingsTabView.swift** - Configuration
- Sources: Baidu/Aliyun auth
- Soniox: API key for STT
- AI Gateway: API key, model selection, credits
- Storage: Cache management (`CacheManagementView`), disk usage breakdown

## Architecture Snapshot
- **Core**: SwiftUI + ObservableObject. AVFoundation for playback. MobileVLCKit for unsupported video formats.
- **Data**: GRDB (SQLite) for library/transcripts. JSON fallback for portability.
- **Modules**:
  - `AudioPlayerViewModel`: AVPlayer wrapper, playback controls, sleep timer, shuffle, remote commands, cache integration, VLC format detection
  - `LibraryStore`: Collection CRUD, playback state persistence, favorites, cover image management
  - `CollectionDetailViewModel`: MVVM for track list with paging (>1000 tracks), filter/sort, transcript/summary status caching
  - `BaiduAuthViewModel` / `BaiduNetdiskClient`: OAuth flow, file listing, streaming URLs
  - `TranscriptionManager`: Soniox API integration, job queue, polling, transcript storage
  - `AIGenerationManager`: LLM job orchestration, summary generation, background polling
  - `AIGatewayViewModel`: API key management, model selection, chat interface
  - `GRDBDatabaseManager`: SQLite persistence layer (collections, tracks, transcripts, summaries, playback states)
  - `AudioCacheManager` / `AudioCacheDownloadManager`: Local audio file caching with byte-range support
  - `PlaybackClock`: High-frequency time updates isolated from main view hierarchy
  - `VLCVideoPlayerView`: MobileVLCKit wrapper for MKV/WebM video playback
  - `PlayableMediaFormat`: Format detection and VLC requirement checking

## Tech Decisions
| Component | Choice | Notes |
|-----------|--------|-------|
| UI | SwiftUI | Modern standard. |
| Audio | AVFoundation | Better control than MediaPlayer. |
| Video | AVPlayer + MobileVLCKit | AVPlayer for MP4/MOV. VLC for MKV/WebM. |
| DB | GRDB + SQLite | Robust, supports complex queries & concurrency. |
| Async | async/await | Used for all network/DB ops. |
| Dependency Management | CocoaPods | For MobileVLCKit integration. |

## Key Files Quick Reference
| Category | Files |
|----------|-------|
| **Main Views** | `ContentView.swift`, `LibraryView.swift`, `SmartView.swift`, `PersonalView.swift` |
| **Playback** | `AudioPlayerViewModel.swift`, `FloatingPlaybackBubbleView.swift`, `VLCVideoPlayerView.swift`, `PlaybackClock` (in AudioPlayerVM) |
| **Collection Detail** | `CollectionDetailView.swift`, `CollectionDetailViewModel.swift` (includes chapter grouping via `chapterGroups`, `hasChapters`) |
| **Import Flows** | `CreateCollectionView.swift`, `CollectionBuilderViewModel.swift`, `BaiduNetdiskBrowserView.swift`, `AddRSSCollectionView.swift`, `CreateEbookCollectionView.swift` |
| **AI/Transcription** | `TranscriptionManager.swift`, `AIGatewayViewModel.swift`, `AIGenerationManager.swift`, `SonioxSTTView.swift`, `EdgeTTSView.swift` |
| **Data Layer** | `LibraryStore.swift`, `GRDBDatabaseManager.swift`, `AudioCacheManager.swift` |
| **Auth** | `BaiduAuthViewModel.swift`, `BaiduNetdiskClient.swift`, `AliyunAuthViewModel.swift` |
| **Settings** | `SettingsTabView.swift`, `CacheManagementView.swift`, `StorageManagementView.swift` |
| **Format Support** | `PlayableMediaFormat.swift` (format detection, VLC requirements) |

## Dev Workflow & Tips
### App Icons
Run `./scripts/generate-app-icons.sh <source-image-path>` to generate all sizes.

### Localization
- **Format**: Ensure file remains JSON, not binary plist.

### Database
- **Sync Location**: Current plan is to keep `library.sqlite` in iCloud-synced container/storage so same DB file syncs between Mac and iPhone.
- **Sync Approach**: File-based sync only. Do not introduce CloudKit or other complex sync stack unless needed later.
- **Reference**: See `local/database-reference-debug.md`.

### Xcode Project
- **Do not edit `project.pbxproj` manually.** Use Xcode UI to add files.
- **Schemes**: Shared scheme `AudiobookPlayer` is in the repo.

## Docs
local/feat/*.md include some detailed refrences docs for some of the features. You can always refer to them firstly to quickly become familiar with them. And remember that when you made some changes, you shoud decide if the related doc should be updated once I have confirm it.
it's not only feat doc, it's also the technical reference doc as well.
