# iOS Audiobook Player - Product Requirements & Architecture

**Repo**: https://github.com/lenohard/happy-bear  
**Tools**: Use `deepwiki` for quick repo details.  
**Build Target**: iPhone 17 Pro simulator.  
**Note**: The `./local/` folder is **NOT** ignored by git for this repository.

## Recent Progress (Dec 2025)
- **MVVM & Performance (Dec 12-15)**: Refactored `CollectionDetailView` to MVVM to fix actor isolation. Implemented background thumbnail generation (320px) + NSCache for smooth library scrolling. Moved heavy model grouping to background tasks.
- **RSS Support (Dec 7)**: Added `.rss` source support, feed import, and remote cover caching. Covers are now prefetched and stored locally.
- **Playback Features (Dec 8)**: Added Random Play (shuffle), fixed Play button token guard (offline play), and improved Floating Bubble visibility using a separate `UIWindow` (level `.alert + 1`).
- **Infrastructure**: Consolidated background DB writes, improved date parsing reliability, and fixed listening history resume stability.

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

### SwiftUI & UI
- **Overlays vs Sheets**: `overlay()` doesn't render above sheets. For persistent UI (bubbles), use a separate `UIWindow` with `PassThroughWindow`.
- **Nested ScrollViews**: Avoid nesting `ScrollView` inside another if using `ScrollViewReader.scrollTo()`.
- **Swipe Actions**: Use `.labelStyle(.iconOnly)` for swipe buttons to ensure centering.

### Baidu & Networking
- **WebSocket Handshake**: Always wait for `didOpenWithProtocol`. Use fresh `URLSession` per request for stability.
- **SSML/XML**: Always escape text input (especially `&`, `<`, `>`) before embedding in SSML. Malformed XML causes the server to drop the connection immediately, leading to confusing "Socket not connected" errors.
- **Collection Refresh**: Relies on fixed folder paths. Renaming the source folder in Netdisk breaks refresh; adding files to the folder is supported.
- **Streaming**: Baidu Netdisk does not natively support WebM streaming.

### Build & Xcode
- **Database Locked**: If `xcodebuild` fails with "database is locked", wait/retry or run `killall xcodebuild` and clear DerivedData.
- **Duplicate Body**: "Declaration only valid at file scope" often means a duplicate `var body: some View` line.
- **Catalyst**: Enable **Keychain Sharing** capability for Mac Catalyst builds to allow Keychain writes in unsigned DMGs.
- **Build Filters**: Use `xcodebuild ... | grep -E "error:|warning:|BUILD"` to reduce noise.

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
- Remote commands: lock screen/control center (play, skip, now playing info, favorite state)
- Session tracking: auto-saves progress, resume from last position

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
- **Core**: SwiftUI + ObservableObject. AVFoundation for playback.
- **Data**: GRDB (SQLite) for library/transcripts. JSON fallback for portability.
- **Modules**:
  - `AudioPlayerViewModel`: AVPlayer wrapper, playback controls, sleep timer, shuffle, remote commands, cache integration
  - `LibraryStore`: Collection CRUD, playback state persistence, favorites, cover image management
  - `CollectionDetailViewModel`: MVVM for track list with paging (>1000 tracks), filter/sort, transcript/summary status caching
  - `BaiduAuthViewModel` / `BaiduNetdiskClient`: OAuth flow, file listing, streaming URLs
  - `TranscriptionManager`: Soniox API integration, job queue, polling, transcript storage
  - `AIGenerationManager`: LLM job orchestration, summary generation, background polling
  - `AIGatewayViewModel`: API key management, model selection, chat interface
  - `GRDBDatabaseManager`: SQLite persistence layer (collections, tracks, transcripts, summaries, playback states)
  - `AudioCacheManager` / `AudioCacheDownloadManager`: Local audio file caching with byte-range support
  - `PlaybackClock`: High-frequency time updates isolated from main view hierarchy

## Tech Decisions
| Component | Choice | Notes |
|-----------|--------|-------|
| UI | SwiftUI | Modern standard. |
| Audio | AVFoundation | Better control than MediaPlayer. |
| DB | GRDB + SQLite | Robust, supports complex queries & concurrency. |
| Async | async/await | Used for all network/DB ops. |

## Key Files Quick Reference
| Category | Files |
|----------|-------|
| **Main Views** | `ContentView.swift`, `LibraryView.swift`, `SmartView.swift`, `PersonalView.swift` |
| **Playback** | `AudioPlayerViewModel.swift`, `FloatingPlaybackBubbleView.swift`, `PlaybackClock` (in AudioPlayerVM) |
| **Collection Detail** | `CollectionDetailView.swift`, `CollectionDetailViewModel.swift` |
| **Import Flows** | `CreateCollectionView.swift`, `CollectionBuilderViewModel.swift`, `BaiduNetdiskBrowserView.swift`, `AddRSSCollectionView.swift`, `CreateEbookCollectionView.swift` |
| **AI/Transcription** | `TranscriptionManager.swift`, `AIGatewayViewModel.swift`, `AIGenerationManager.swift`, `SonioxSTTView.swift`, `EdgeTTSView.swift` |
| **Data Layer** | `LibraryStore.swift`, `GRDBDatabaseManager.swift`, `AudioCacheManager.swift` |
| **Auth** | `BaiduAuthViewModel.swift`, `BaiduNetdiskClient.swift`, `AliyunAuthViewModel.swift` |
| **Settings** | `SettingsTabView.swift`, `CacheManagementView.swift`, `StorageManagementView.swift` |

## Dev Workflow & Tips
### App Icons
Run `./scripts/generate-app-icons.sh <source-image-path>` to generate all sizes.

### Localization
- **Format**: Ensure file remains JSON, not binary plist.

### Database
- **Location**: `~/Library/Containers/.../library.sqlite`
- **Reference**: See `local/database-reference-debug.md`.

### Xcode Project
- **Do not edit `project.pbxproj` manually.** Use Xcode UI to add files.
- **Schemes**: Shared scheme `AudiobookPlayer` is in the repo.
