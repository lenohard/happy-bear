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
- **Collection Refresh**: Relies on fixed folder paths. Renaming the source folder in Netdisk breaks refresh; adding files to the folder is supported.
- **Streaming**: Baidu Netdisk does not natively support WebM streaming.

### Build & Xcode
- **Database Locked**: If `xcodebuild` fails with "database is locked", wait/retry or run `killall xcodebuild` and clear DerivedData.
- **Duplicate Body**: "Declaration only valid at file scope" often means a duplicate `var body: some View` line.
- **Catalyst**: Enable **Keychain Sharing** capability for Mac Catalyst builds to allow Keychain writes in unsigned DMGs.
- **Build Filters**: Use `xcodebuild ... | grep -E "error:|warning:|BUILD"` to reduce noise.

## Main Views & Workflows
### Playback
- **Core**: `ContentView.swift` (Root TabView + `PlayingView` implementation), `AudioPlayerViewModel.swift` (Logic).
- **Overlay**: `FloatingPlaybackBubbleView.swift` (Global bubble), `FloatingPlaybackBubbleViewModel.swift`.
- **Logic**: `PlaybackSnapshot` (State persistence), `MPRemoteCommandCenter` (Lock screen controls).

### Library Management
- **List**: `LibraryView.swift` (Main list), `LibraryStore.swift` (Data source/GRDB).
- **Detail**: `CollectionDetailView.swift` (Track list, Sort/Filter, Batch Actions), `CollectionDetailViewModel.swift` (MVVM logic).
- **Import**: `CreateCollectionView.swift` (Import flow), `BaiduNetdiskBrowserView.swift` (File picker), `CollectionBuilderViewModel.swift`.

### AI & Transcription
- **Hub**: `SmartView.swift` (Container for AI/TTS tabs).
- **Transcription**: `TranscriptionSheet.swift` (Job progress), `TranscriptViewerSheet.swift` (Result viewer), `TranscriptionManager.swift` (Soniox logic).
- **LLM**: `AIGatewayViewModel.swift` (Chat/Summary logic).

### Personal & Settings
- **Profile**: `PersonalView.swift` (History, Stats, Settings container).
- **Settings**: `SettingsTabView.swift` (Config), `CacheManagementView.swift` (Storage control).

## Architecture Snapshot
- **Core**: SwiftUI + ObservableObject. AVFoundation for playback.
- **Data**: GRDB (SQLite) for library/transcripts. JSON fallback for portability.
- **Modules**:
  - `AudioPlayerViewModel`: Playback, remote commands, session.
  - `LibraryStore`: Collections, favorites, persistence.
  - `BaiduAuthViewModel` / `BaiduNetdiskClient`: Auth & File operations.
  - `TranscriptionManager`: Soniox integration (Upload -> Job -> Transcript).
  - `AIGatewayViewModel`: LLM integration.

## Tech Decisions
| Component | Choice | Notes |
|-----------|--------|-------|
| UI | SwiftUI | Modern standard. |
| Audio | AVFoundation | Better control than MediaPlayer. |
| DB | GRDB + SQLite | Robust, supports complex queries & concurrency. |
| Async | async/await | Used for all network/DB ops. |

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
