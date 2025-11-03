# iOS Audiobook Player

An iOS app for playing audiobooks and audio files stored in Baidu Cloud Drive (百度云盘).

## Features (Planned)
- 🎵 Stream audio directly from Baidu Cloud
- 📚 Local library management
- 🔖 Bookmark playback positions
- ⚡ Variable playback speed
- ⏱️ Sleep timer
- 📱 iCloud sync (planned)
- 🌙 Dark mode support

## Supported Audio Formats
The app supports all iOS native audio formats through AVFoundation, including:
- **MP3** - MPEG-1 Audio Layer 3
- **M4A/M4B** - AAC encoded audio (M4B for audiobooks with chapters)
- **AAC** - Advanced Audio Coding
- **FLAC** - Lossless audio format
- **WAV** - Uncompressed audio
- **Opus** - Efficient compression format
- **OGG** - Open source audio format
- Plus other iOS-supported formats (ALAC, AIFF, CAF, etc.)

## Project Status
**Stage**: Active Development (Core Features Implemented)

### Current Implementation
- ✅ Baidu OAuth authentication with secure token storage
- ✅ Audio playback with AVFoundation
- ✅ Background audio support
- ✅ Library management with local JSON storage
- ✅ Playback progress tracking
- ✅ CloudKit sync support
- ✅ Responsive UI with SwiftUI

### Data Storage
- **Library Data**: Local JSON file (`~/Library/Application Support/AudiobookPlayer/library.json`)
- **Authentication**: Secure Keychain storage for Baidu tokens
- **Sync**: CloudKit integration for cross-device synchronization

See [PROD.md](./PROD.md) for detailed requirements, architecture decisions, and progress tracking.

## Quick Start
1. Open `AudiobookPlayer.xcodeproj` in Xcode (or run `xed AudiobookPlayer.xcodeproj` from the project root).
2. Select the **AudiobookPlayer** scheme and run on an iOS 16+ simulator or device.
3. Tap “Load Sample Audio” to stream the demo URL through `AVPlayer`.

## Development

### Prerequisites
- Xcode 15+
- iOS 15+ deployment target
- Baidu Cloud account for testing

### Build
```bash
# Inspect available targets & schemes
cd ~/projects/audiobook-player
xcodebuild -list -project AudiobookPlayer.xcodeproj

# Open the project in Xcode
xed AudiobookPlayer.xcodeproj
```

### Baidu OAuth Setup
1. Register an app in [Baidu Developer Center](https://developer.baidu.com/) and enable Netdisk (Baidu Pan) permissions.
2. Replace the placeholders in `AudiobookPlayer/Info.plist`:
   - `BaiduClientId`
   - `BaiduClientSecret`
   - `BaiduRedirectURI` (must use the same custom scheme added under `CFBundleURLTypes`)
   - `BaiduScope` (defaults to `basic netdisk` for read-only Netdisk access)
3. Update the custom URL scheme in `CFBundleURLTypes` if you change the redirect URI scheme.
4. Run the app; use the “Sign in with Baidu” button to complete the OAuth flow and fetch an access token.

## Documentation
- **PROD.md**: Product requirements, architecture, planning, and progress
- **AGENTS.md**: Project memory for AI agents and future sessions
- **local/docs/**: Session-specific documentation

## Current Development Focus
- Improving library loading performance and user experience
- Adding loading states and skeleton screens
- Enhancing error handling and offline support

## License
TBD
