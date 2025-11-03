# iOS Audiobook Player - Product Requirements & Architecture

# Current Task 
local/PROD.md:
@local/PROD.md

## Project Overview
An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

**Project Root**: `~/projects/audiobook-player`

---

## Development Scripts

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
```
Baidu Cloud API
      ↓
BaiduCloudModule (fetch files, stream URLs)
      ↓
AudioPlaybackModule (play audio)
      ↓
LibraryModule (store progress, metadata)
      ↓
UI (display & user interaction)
```

---

## Implementation Plan

### Phase 1: Foundation (MVP)
- [x] Project setup with SwiftUI + AVFoundation
- [x] Baidu OAuth2 authentication flow (authorization code + token exchange skeleton)
- [x] Basic file listing from Baidu Cloud
- [ ] Simple audio player with basic controls (play/pause/skip)
- [ ] Playback progress tracking
- [ ] Basic UI (now playing screen, library view)

### Phase 2: Core Features
- [ ] Bookmarking/resuming playback position
- [ ] Local library management
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
- [ ] Will you use Baidu's official OAuth2 flow, or do you have an existing Baidu account token?
- [ ] Should the app support multiple Baidu accounts?
- [ ] Do you need secure credential storage (Keychain)?

### 2. **Audio File Support**
- [ ] What audio formats do you primarily use? (MP3, M4A, FLAC, OGG, etc.)
- [ ] Are files single tracks or do you have folders/playlists on Baidu?
- [ ] Max audio file size you expect to handle?

### 3. **Playback Features Priority**
- [ ] Must-have features (rank by importance):
  - [ ] Play/pause/skip
  - [ ] Bookmark/resume position
  - [ ] Speed control
  - [ ] Sleep timer
  - [ ] Offline download
  - [ ] Metadata display

### 4. **Data Storage & Sync**
- [ ] Should playback progress sync across iOS devices? (requires iCloud or server backend)
- [ ] Do you want local caching of frequently played audiobooks?
- [ ] Preferred local storage approach: SwiftData vs Core Data?

### 5. **UI/UX Preferences**
- [ ] Preferred app design style/inspiration?
- [ ] Dark mode support required?
- [ ] Minimum iOS version? (iOS 15, 16, 17?)
- [ ] Support iPad as well?

### 6. **Performance & Streaming**
- [ ] Should audio stream directly from Baidu, or require local download?
- [ ] Expected offline usage percentage?
- [ ] Cellular data restrictions needed?

### 7. **Testing & Distribution**
- [ ] Will you publish to App Store, TestFlight beta, or personal use only?
- [ ] Do you have an Apple Developer account?

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

### Session: 2025-11-02
- [x] Project directory created
- [x] PROD.md initialized with architecture & planning
- [ ] Awaiting user clarification on above questions
- [x] Integrated Baidu OAuth sign-in UI backed by `ASWebAuthenticationSession` and token exchange service
- [x] Added Info.plist placeholders for Baidu credentials and custom URL scheme registration
- [x] Verified simulator build locally via `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -destination 'generic/platform=iOS Simulator' build`


### Session: 2025-02-11
- [x] Initialized `AudiobookPlayer.xcodeproj` with SwiftUI target and AVFoundation dependency
- [x] Added starter `AudioPlayerViewModel` and `ContentView` scaffolding
- [x] Documented run instructions in README

### Commits Log
*(To be updated as development progresses)*

### Notes
- Will use this PROD.md as central documentation for decisions and progress
- Commit history will be logged here for future reference
- Questions and blockers will be tracked in this file

## Research & Documentation
### Baidu OAuth2 & Baidu Pan Integration
- **Location**: ./`local/docs/baidu-oauth2-research.md`
- **Status**: Initial Research
- **Purpose**: iOS app integration with Baidu Pan (cloud storage) for file access
- **Key Finding**: OAuth2 allows user approval to grant app access to Baidu Pan files
- **Token Endpoint**: `https://aip.baidubce.com/oauth/2.0/token`
- **Next Steps**: Verify Baidu Pan API availability, find authorization endpoint, document scopes
