# iOS Audiobook Player - Product Requirements & Architecture

# Current Task 
local/PROD.md:
@local/PROD.md

- Background audio + enhanced playback controls completed 2025-11-03

## Project Overview
An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

**Project Root**: `~/projects/audiobook-player`

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

## Architecture Suggestions

### Tech Stack (Proposed)
- **Language**: Swift
- **UI Framework**: SwiftUI (modern, declarative, easier maintenance)
- **Audio Playback**: AVFoundation (native iOS audio framework)
- **Networking**: URLSession + Combine for reactive programming
- **Data Persistence**: SwiftData or Core Data (for playback progress, library)
- **Baidu API Integration**: Custom HTTP client for Baidu Cloud API

### Core Modules
1. **BaiduCloudModule**
   - OAuth2 authentication with Baidu
   - File listing and browsing
   - Audio file streaming
   - Metadata extraction

2. **AudioPlaybackModule**
   - AVFoundation-based player
   - Queue management
   - Playback state management
   - Audio session handling

3. **LibraryModule**
   - Local audiobook library
   - Metadata storage (title, author, duration)
   - Playback progress tracking
   - Favorites/playlists

4. **UIModule**
   - Now Playing screen
   - Library browser
   - Baidu Cloud file browser
   - Settings & preferences

### Data Flow
### Phase 1: Foundation (MVP)
- [x] Project setup with SwiftUI + AVFoundation
- [x] Baidu OAuth2 authentication flow (authorization code + token exchange skeleton)
- [x] Basic file listing from Baidu Cloud
- [x] Simple audio player with basic controls (play/pause/skip)
- [x] Playback progress tracking
- [x] Basic UI (now playing screen, library view)

### Phase 2: Core Features
- [x] Bookmarking/resuming playback position
- []  Bookmarking for Netdisk path
- [x] Local library management
- [ ] Metadata display (title, artist, duration)
- [ ] Playlist/collection organization
- [ ] Speed control (0.75x, 1x, 1.25x, 1.5x, etc.)
- [ ] Seek bar with scrubbing

### Phase 3: Enhancement
- [ ] Sleep timer
- [ ] Offline download support (cache audio locally)
- [ ] Search functionality
- [ ] Custom sorting/filtering
- [ ] iCloud sync for progress across devices
- [ ] Dark mode support
- [ ] Lock screen playback controls

### Phase 4: Polish & Distribution
- [ ] Unit tests
- [ ] UI/UX refinement
- [ ] Performance optimization
- [ ] App Store submission preparation
- [ ] Beta testing

---

## Key Clarifications Needed
### 1. **Authentication & Access**
- [x] Do you need secure credential storage (Keychain)?
Yes

### 2. **Audio File Support**
- [x] What audio formats do you primarily use? (MP3, M4A, FLAC, OGG, etc.) 
MP3, M4A, FLAC

### 4. **Data Storage & Sync**
- [ ] Should playback progress sync across iOS devices? (requires iCloud or server backend)
- [ ] Do you want local caching of frequently played audiobooks?
Yes
- [ ] Preferred local storage approach: SwiftData vs Core Data?
目前使用 JSON 后续需要更改

### 5. **UI/UX Preferences**
- [x] Minimum iOS version? 
IOS 16
- [x] Support iPad as well?
YES

### 6. **Performance & Streaming**
- [ ] Should audio stream directly from Baidu, or require local download?
- [ ] Expected offline usage percentage?

---

## Technology Decisions

| Component | Options | Recommendation | Notes |
|-----------|---------|-----------------|-------|
| UI Framework | UIKit vs SwiftUI | **SwiftUI** | Easier to maintain, modern iOS standard |
| Audio Framework | AVFoundation vs MediaPlayer | **AVFoundation** | More control, better for custom UI |
| Database | Core Data vs SwiftData | **SwiftData** | Newer, simpler, integrated with Concurrency |
| Networking | URLSession vs Alamofire | **URLSession** | Built-in, sufficient for this use case |
| Async Concurrency | Callbacks vs async/await | **async/await** | Modern Swift standard (iOS 13+) |

---

## Risk & Considerations

1. **Baidu API Rate Limiting**: Need to handle API rate limits gracefully
2. **Audio Streaming Reliability**: Handle network interruptions, buffering
3. **OAuth Token Refresh**: Implement automatic token refresh before expiry
4. **Battery & Data Usage**: Streaming can consume significant resources
5. **Privacy**: Securely store Baidu credentials in Keychain
6. **App Store Policy**: Verify app complies with Apple's guidelines for cloud storage integration

---

## Next Steps

1. **Your Input**: Answer the clarification questions above
2. **Project Structure**: Set up Xcode project with folder organization
3. **Baidu API Research**: Identify required endpoints and authentication flow
4. **Prototype**: Build basic MVP with authentication + file listing
5. **Iterate**: Add features based on priority

---

## Progress Tracking

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

## Research & Documentation
### Baidu OAuth2 & Baidu Pan Integration
- **Location**: ./`local/docs/baidu-oauth2-research.md`
- **Status**: Initial Research
- **Purpose**: iOS app integration with Baidu Pan (cloud storage) for file access
- **Key Finding**: OAuth2 allows user approval to grant app access to Baidu Pan files
- **Token Endpoint**: `https://aip.baidubce.com/oauth/2.0/token`
- **Next Steps**: Verify Baidu Pan API availability, find authorization endpoint, document scopes

## Qwen Added Memories
- 用户数据存储架构：
1. 播放进度和图书馆数据 - 存储在本地JSON文件（~/Library/Application Support/AudiobookPlayer/library.json），使用LibraryStore和LibraryPersistence类管理
2. 百度认证Token - 存储在iOS Keychain中，使用KeychainBaiduOAuthTokenStore类安全存储
3. 数据同步 - 通过CloudKitLibrarySync支持多设备同步，基于时间戳的冲突解决
4. 存储特点 - 离线优先、自动保存、版本控制（schemaVersion=2）
5. 数据模型 - AudiobookCollection（有声书集合）、TrackPlaybackState（播放状态）、支持百度网盘/本地/外部链接三种来源
