# iOS Audiobook Player - Product Requirements & Architecture

# Current Task 
local/PROD.md:
@local/PROD.md

- Background audio + enhanced playback controls completed 2025-11-03

## Project Overview
An iOS application for playing audiobooks stored in Baidu Cloud Drive (百度云盘), with seamless integration for importing, managing, and playing audio files.

**Project Root**: `~/projects/audiobook-player`

### Build & Schemes
- Shared Xcode scheme `AudiobookPlayer.xcodeproj/xcshareddata/xcschemes/AudiobookPlayer.xcscheme` lives in the repo so `xcodebuild -scheme AudiobookPlayer` (CI, scripts, other agents) can resolve SwiftPM packages. Keep it under version control; removing it breaks command-line builds.

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

---

## Xcode Project Tips

- **Adding localized strings without Xcode UI**: update `project.pbxproj` by creating a `PBXVariantGroup` named `Localizable.strings`, add language `PBXFileReference` entries (for example `en.lproj/Localizable.strings`, `zh-Hans.lproj/Localizable.strings`), include the group under the main app group, add a `PBXBuildFile`, and list it in the target’s Resources build phase so Xcode picks up the localized bundles automatically.
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

### Session: 2025-11-03 (Continued - Multi-Language Phase 2)
**Multi-Language Support Localization Setup** 📝
- [x] Generated `.strings` files from `Localizable.xcstrings`:
  - Created `AudiobookPlayer/en.lproj/Localizable.strings` with 62 English strings
  - Created `AudiobookPlayer/zh-Hans.lproj/Localizable.strings` with 62 Chinese strings
- [x] Verified all Chinese translations for accuracy and cultural appropriateness
- [x] Built and verified app compiles without errors
- ⚠️ **PENDING - Manual Xcode Setup Required**:
  - Localization folders exist on filesystem but need to be added to Xcode project
  - User must open project in Xcode and add `en.lproj` & `zh-Hans.lproj` to Build Phases > Copy Bundle Resources
  - Once added: clean build, test in Chinese device language setting

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

2. **Filtering Xcode Build Output**: Xcode build output can be very large (thousands of lines). Use grep to filter and check for specific conditions:
   - **Check for errors**: `xcodebuild ... | grep -i error`
   - **Check for warnings**: `xcodebuild ... | grep -i warning`
   - **Check for success**: `xcodebuild ... | grep -i "build succeeded"`
   - **See last lines**: `xcodebuild ... | tail -n 20`
   - This saves tokens and makes build verification more efficient

3. **⚠️ CRITICAL - Localizable.xcstrings File Corruption Protection**:
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

4. **Xcode Project File Editing**: Never attempt to programmatically edit `project.pbxproj`. Instead:
   - Generate required resource files (`.strings`, `.xcassets`, etc.) using scripts
   - Create necessary directory structure (`*.lproj`, etc.)
   - Ask user to manually add files/folders to Xcode project via UI (Build Phases > Copy Bundle Resources, etc.)
   - User then builds and tests in Xcode
   This prevents pbxproj corruption and ensures proper project configuration.

5. **UI Localization Best Practices**: When writing UI code, always use localization keys for multi-language support:
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
   - **Process**: When adding new UI strings:
     1. Use descriptive localization keys in code
     2. Add entries to `AudiobookPlayer/Localizable.xcstrings`
     3. Generate `.strings` files via `generate_strings.py`
     4. User manually adds to Xcode project
     5. Test in both English and Chinese device settings

6. **Avoid Over-Automation for Small Localization Changes**:
   - ❌ **DON'T**: Build scripts to regenerate `.strings` files for small edits (3-5 strings)
   - ✅ **DO**: Directly edit `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings` by hand (copy-paste, ~1 minute)
   - ✅ **DO**: Update `generate_strings.py` SCRIPT dictionary for future regenerations
   - **Lesson**: Task was 10 lines of manual edits, but I built a Python script instead (wasted ~15 minutes on automation). For surgical changes to static files, direct editing beats scripting.

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


## Documentation Index
- `local/docs/siri-collection-playback.md`: Siri/App Intents setup for triggering collection playback via voice and Shortcuts.

## Database Reference (STT & Library)
- **Main Database**: `~/Library/Containers/6DAE9FFA-3650-44C2-9FD6-788F8AC6FB2E/Data/Library/Application Support/AudiobookPlayer/library.sqlite`
- **Database Type**: SQLite with GRDB ORM
- **Key Tables**: `transcripts`, `transcript_segments`, `transcription_jobs`, `collections`, `tracks`, `playback_states`
- **Documentation**: See `local/database-reference-debug.md` for full schema, queries, and debug commands
- **Current State (2025-11-09)**: 1 transcript with 16 segments, 4250+ chars of text, marked as "complete"
- **Known Issue**: Transcript data is saved in DB but TranscriptViewerSheet shows blank (investigate state refresh)

## Qwen Added Memories
- UI Localization Best Practices: When writing UI code, always use localization keys for multi-language support. Use Text("search_files") with corresponding entries in Localizable.xcstrings, not hardcoded strings like Text("Search files"). Process: 1) Use descriptive localization keys in code, 2) Add entries to Localizable.xcstrings, 3) Generate .strings files via generate_strings.py, 4) User manually adds to Xcode project, 5) Test in both English and Chinese device settings.
