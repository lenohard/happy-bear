# iOS Audiobook Player — Agent Guide
**Repo**: https://github.com/lenohard/happy-bear | **Build**: iPhone 17 Pro simulator | **Note**: `./local/` is tracked by git

## Project Overview
iOS audiobook player for Baidu Cloud Drive (百度云盘). Import, manage, and play audio files with AI-powered transcription and summaries.

**Tech Stack**: SwiftUI + ObservableObject · AVFoundation + MobileVLCKit · GRDB (SQLite) · CocoaPods · async/await

## Architecture & Key Patterns
- **MVVM**: Dedicated ViewModels for complex views (e.g. `CollectionDetailViewModel`). Call GRDB from `async` methods, never synchronous wrappers.
- **High-Frequency State**: Use `PlaybackClock` (dedicated ObservableObject) for timeline ticks — never publish from main `AudioPlayerViewModel`.
- **Scroll Performance**: Preload images to NSCache in `Task.detached`. View `onAppear` checks cache synchronously.
- **Background Tasks**: iOS suspends polling/sockets. Check job status on `scenePhase` foreground resume.
- **Data Model Names**: `AudiobookCollection.title` vs `AudiobookTrack.displayName` (no `title`). Use `localizedCaseInsensitiveContains` for search.
- **DB Sync**: Simple file-based — `library.sqlite` in iCloud-synced container. No CloudKit unless explicitly needed.

## Video & Audio Playback
- **Format Routing**: MP4/MOV → AVPlayer. MKV/WebM → VLC audio-only (`startVLCAudioPlayback()`). Use `PlayableMediaFormat.requiresVLC()`.
- **VLC Threading**: All `player.drawable` ops on main thread (`Thread.isMainThread` guard + `DispatchQueue.main.async`). Fixes OpenGL crashes.
- **VLC Drawable Rebinding**: `VLCHostView` rebinds drawable in `layoutSubviews()` and `updateUIView()` when reopening minimized session.
- **Scrubbing**: `seek(to:resumeAfterSeek:)` resumes inside seek completion handler. `isScrubbingActive` flag prevents `timeControlStatus` observer interference. Never call `play()` before async seek completes.
- **Background Audio Startup**: Activate session + background task before each play. `resumePlaybackIfStalled()` on foreground resume. Guard `.paused` observer with `lastPlayRequestDate == nil`.
- **Video Presentation**: `VideoPresentationMode` enum (hidden/fullscreen/mini). PiP restore delegates to sheet via `restoreUserInterfaceForPictureInPictureWithCompletionHandler`.

## SwiftUI & UI
- **Overlays vs Sheets**: `overlay()` doesn't render above sheets. Use separate `UIWindow` (level `.alert + 1`) for persistent UI (floating bubble).
- **Nested ScrollViews**: Avoid nesting if using `ScrollViewReader.scrollTo()`.
- **Swipe Actions**: Use `.labelStyle(.iconOnly)` for centering.
- **Type-Checker Timeout**: Split long modifier chains with `let` variables (≤10 modifiers each). Follow `viewWith*` naming convention. Extract large `.onChange`/`.onAppear` closures to methods.
- **Text Selection**: `.textSelection(.enabled)` fails inside ScrollView + Button + VStack combos. Use `UITextView` wrapper (`SelectableText`) for reliable partial text selection.

## Baidu & Networking
- **WebSocket**: Wait for `didOpenWithProtocol`. Fresh `URLSession` per request.
- **SSML/XML**: Escape `&`, `<`, `>` before embedding. Malformed XML drops connection silently.
- **Collection Refresh**: Fixed folder paths — renaming source folder in Netdisk breaks refresh.
- **Streaming**: Baidu Netdisk does not natively support WebM streaming.

## Build & Xcode
- **Workspace**: No `.xcworkspace` — use `-project AudiobookPlayer.xcodeproj` (always `ls *.xcworkspace` first to verify).
- **CocoaPods**: Run `pod install` after Podfile changes. Use `pod deintegrate && pod install` to reset framework issues.
- **Database Locked**: `killall xcodebuild` and clear DerivedData.
- **Duplicate Body**: "Declaration only valid at file scope" usually means duplicate `var body: some View`.
- **Warnings**: Many warnings in project — filter with `2>&1 | grep -E "error:|BUILD"` by default.
- **tmux + grep**: grep filtering causes tmux stall false positives during long builds. Use `subscribe=false` or pipe to log file.
- **TestFlight Upload**: `asc builds upload` needs `.ipa` not `.xcarchive`. Create IPA: `mkdir Payload && cp -R xcarchive/Products/Applications/HappyBear.app Payload/ && zip -r HappyBear.ipa Payload/`.
- **Catalyst**: Enable Keychain Sharing for unsigned Mac DMGs.
- **DMG**: `scripts/package-maccatalyst-dmg.sh` with optional `SIGN=1 NOTARIZE=1`.

## Chapter Support
- Parent folder name = chapter. Files at root = nil chapter. `chapterGroups` computed in ViewModel. Optional — old data displays flat list.

## Key Files
| Category | Files |
|----------|-------|
| **Main Views** | `ContentView.swift`, `LibraryView.swift`, `SmartView.swift`, `PersonalView.swift` |
| **Playback** | `AudioPlayerViewModel.swift`, `FloatingPlaybackBubbleView.swift`, `VLCVideoPlayerView.swift` |
| **Collection** | `CollectionDetailView.swift` + `CollectionDetailViewModel.swift` |
| **Import** | `CreateCollectionView.swift`, `CollectionBuilderViewModel.swift`, `BaiduNetdiskBrowserView.swift` |
| **AI/STT** | `TranscriptionManager.swift`, `AIGatewayViewModel.swift`, `AIGenerationManager.swift` |
| **Data** | `LibraryStore.swift`, `GRDBDatabaseManager.swift`, `AudioCacheManager.swift` |
| **Auth** | `BaiduAuthViewModel.swift`, `BaiduNetdiskClient.swift`, `AliyunAuthViewModel.swift` |
| **Format** | `PlayableMediaFormat.swift` |

## Workflow
- **Docs**: Use `local/feat/*.md` for feature reference. Update related docs after confirmed changes.
- **Icons**: `./scripts/generate-app-icons.sh <source-image-path>`
- **pbxproj**: Never edit manually — use Xcode UI to add files.

## Recent Progress
- **Jul 2026**: Release signing fix (Manual + Apple Distribution in pbxproj), SwiftUI text selection fix (UITextView wrapper), builds 31-32.
- **May 2026**: Global search across collections/tracks. v0.3.2 build 19.
- **Apr 2026**: Remote STT server fix (Tailscale Serve misconfiguration).
- **Feb 2026**: Chapter support for collections with subfolders.
- **Dec 2025**: VLC audio-only, MVVM refactor, RSS support, floating bubble, playback features.
