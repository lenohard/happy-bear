# iOS Audiobook Player - Data Storage Architecture Analysis

## Executive Summary

The audiobook player uses a **multi-layered storage strategy**:
- **Keychain** for secure Baidu OAuth tokens
- **File-based JSON** for local library data and playback state
- **CloudKit** (optional) for remote sync of library collections
- **In-memory state** for active playback with periodic persistence

This document provides a comprehensive analysis of how user configuration, authentication, playback state, and library data are stored and managed.

---

## 1. Authentication & Credential Storage

### Baidu OAuth Token Storage (Keychain)
**Primary Storage: Keychain**
**File:** `/Users/senaca/projects/audiobook-player/AudiobookPlayer/BaiduTokenStore.swift`

#### Implementation Details

**Service Key:**
- Service: `com.wdh.audiobook.baidu.oauth`
- Account: `baidu_oauth_token`

**Data Model:** `BaiduOAuthToken` (Codable)
```swift
struct BaiduOAuthToken: Codable, Equatable {
    let accessToken: String              // OAuth2 access token
    let expiresIn: TimeInterval           // Token lifetime in seconds
    let refreshToken: String?             // Optional refresh token
    let scope: String?                    // OAuth2 scope
    let sessionKey: String?               // Baidu session key
    let sessionSecret: String?            // Baidu session secret
    let receivedAt: Date                  // Token receipt timestamp
}
```

**Storage Mechanism:**
1. **Save:** Token is JSON-encoded and stored in macOS/iOS Keychain using `SecItemAdd()` 
2. **Load:** Retrieved via `SecItemCopyMatching()` with query parameters
3. **Update:** Uses `SecItemUpdate()` when duplicate key exists
4. **Delete:** Removed via `SecItemDelete()`

**Encoding Strategy:**
- Dates encoded as seconds since 1970 epoch
- JSON serialization with `JSONEncoder`/`JSONDecoder`

**Why Keychain?**
- Secure storage protected by device encryption
- Not accessible to other apps
- Survives app reinstalls
- Cannot be easily extracted without device unlock

**Token Access Points:**
- `BaiduAuthViewModel.loadPersistedToken()` - loads token on app startup
- `BaiduAuthViewModel.signIn()` - saves token after OAuth authorization
- `BaiduAuthViewModel.signOut()` - clears token from Keychain
- `AudioPlayerViewModel.play()` - uses token for streaming URLs

**Token Expiry Management:**
```swift
var isExpired: Bool {
    Date() >= expiresAt  // Checked in loadPersistedToken()
}
```
- Expired tokens are cleared automatically
- Not automatically refreshed (requires new sign-in)

---

## 2. Library & Collection Storage

### Local Library File Storage (JSON)
**Primary Storage: File-based JSON**
**File:** `/Users/senaca/projects/audiobook-player/AudiobookPlayer/LibraryStore.swift`

#### File Location
```
~/Library/Application Support/AudiobookPlayer/library.json
```
Determined by `LibraryPersistence.makeDefaultURL()`:
```swift
let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
return appSupport
    .appendingPathComponent("AudiobookPlayer", isDirectory: true)
    .appendingPathComponent("library.json", isDirectory: false)
```

#### Data Models

**LibraryFile (Root Container):**
```swift
struct LibraryFile: Codable {
    var schemaVersion: Int                      // Current: 2
    var collections: [AudiobookCollection]      // Array of audiobook collections
}
```

**AudiobookCollection (Main Model):**
```swift
struct AudiobookCollection: Identifiable, Codable, Equatable {
    let id: UUID                                 // Unique collection ID
    var title: String                            // Collection title
    var author: String?                          // Optional author name
    var description: String?                     // Optional description
    var coverAsset: CollectionCover             // Cover art (solid, image, or remote URL)
    var createdAt: Date                         // Creation timestamp
    var updatedAt: Date                         // Last modification timestamp
    var source: Source                          // Where tracks come from (Baidu, local, external)
    var tracks: [AudiobookTrack]                // Array of audio tracks
    var lastPlayedTrackId: UUID?                // Track to resume from
    var playbackStates: [UUID: TrackPlaybackState]  // Per-track playback progress
    var tags: [String]                          // User-defined tags
}
```

**AudiobookTrack (Track Model):**
```swift
struct AudiobookTrack: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String                      // Track display name
    var filename: String                         // Original filename
    var location: Location                       // Where to find the track
    var fileSize: Int64                         // Track file size
    var duration: TimeInterval?                  // Track duration in seconds
    var trackNumber: Int                         // Order in collection
    var checksum: String?                        // Optional file hash
    var metadata: [String: String]              // Custom metadata
}
```

**TrackPlaybackState (Progress Tracking):**
```swift
struct TrackPlaybackState: Codable, Equatable {
    var position: TimeInterval                  // Playback position in seconds
    var duration: TimeInterval?                 // Track duration in seconds
    var updatedAt: Date                         // Last update timestamp
}
```

**CollectionSource (Multi-Source Support):**
```swift
enum Source: Codable, Equatable {
    case baiduNetdisk(folderPath: String, tokenScope: String)
    case local(directoryBookmark: Data)
    case external(description: String)
}
```
- Baidu files are identified by folder path + token scope
- Local files stored as Security Framework bookmarks (allows access after permission)
- External sources identified by description string

**CollectionCover (Cover Art):**
```swift
enum Kind: Codable, Equatable {
    case solid(colorHex: String)                 // Solid color background
    case image(relativePath: String)             // Local image file path
    case remote(url: URL)                        // Remote image URL
}
```

#### Persistence Mechanism

**LibraryPersistence Actor:**
```swift
actor LibraryPersistence {
    static let `default` = LibraryPersistence()
    
    private let fileURL: URL                     // JSON file path
    private let fileManager: FileManager         // File operations
    
    func load() throws -> LibraryFile           // Load from disk
    func save(_ file: LibraryFile) throws        // Save to disk
}
```

**Load Process:**
1. Check if file exists at `~/Library/Application Support/AudiobookPlayer/library.json`
2. If missing, return empty LibraryFile with version 1
3. Read file as Data
4. Decode JSON with ISO8601 date strategy
5. Validate schema version ≤ 2

**Save Process:**
1. Encode LibraryFile to JSON (pretty-printed, sorted keys)
2. Write to temporary `.tmp` file (atomic safety)
3. Delete existing file if present
4. Move temp file to final location (ACID-like safety)

**Encoding Strategy:**
- JSON with ISO8601 date format
- Pretty-printed for readability
- Sorted keys for consistent output

#### Schema Evolution

**Version History:**
- **v1:** Initial schema with `playbackStates: [UUID: TrackPlaybackState]`
- **v2:** Current version (identical structure, schemaVersion field added)

**Migration Logic:**
```swift
if file.schemaVersion < schemaVersion {
    persistCurrentSnapshot()  // Upgrade v1 to v2 on load
}
```

Also supports legacy migration:
```swift
// If v1 file with old "lastPlaybackPosition" field exists
let decodedStates = try container.decodeIfPresent([UUID: TrackPlaybackState].self, ...)
if decodedStates.isEmpty && let legacyPosition = try container.decodeIfPresent(TimeInterval.self, forKey: .legacyLastPlaybackPosition) {
    // Convert to new playbackStates format
}
```

#### Main Thread Safety

**LibraryStore Responsibilities:**
```swift
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var collections: [AudiobookCollection] = []
    @Published private(set) var lastError: Error?
}
```

- Marked with `@MainActor` to ensure all updates happen on main thread
- Uses `@Published` for SwiftUI reactivity
- Async persistence runs on background thread via `Task(priority: .utility)`
- Debounces saves to avoid excessive disk I/O

#### Playback Progress Tracking

**Update Method:**
```swift
func recordPlaybackProgress(
    collectionID: UUID,
    trackID: UUID,
    position: TimeInterval,
    duration: TimeInterval?
)
```

**Key Features:**
- Only persists if position changes by ≥5 seconds (debounces)
- Only persists if duration changes by ≥1 second (reduces noise)
- Updates `collection.lastPlayedTrackId` to remember resume point
- Clamped to non-negative values
- Automatically triggers remote sync if CloudKit enabled

**Called From:**
- `AudioPlayerViewModel.addPeriodicTimeObserver()` - every 0.5 seconds during playback
- `AudioPlayerViewModel.seek()` - when user scrubs
- `ContentView` / `CollectionDetailView` - when user interacts

#### Example Library.json Structure

```json
{
  "schemaVersion": 2,
  "collections": [
    {
      "id": "uuid-string",
      "title": "My Audiobook",
      "author": "Author Name",
      "createdAt": "2025-11-03T10:00:00Z",
      "updatedAt": "2025-11-03T16:00:00Z",
      "coverAsset": {
        "kind": {
          "type": "solid",
          "colorHex": "#5B8DEF"
        },
        "dominantColorHex": null
      },
      "source": {
        "type": "baiduNetdisk",
        "folderPath": "/百度云盘/audiobooks",
        "tokenScope": "basic,netdisk"
      },
      "tracks": [
        {
          "id": "track-uuid",
          "displayName": "Chapter 1",
          "filename": "01_chapter_1.mp3",
          "location": {
            "type": "baidu",
            "fsId": 12345,
            "path": "/audiobooks/01_chapter_1.mp3"
          },
          "duration": 3600.5,
          "trackNumber": 1,
          "fileSize": 43200000,
          "checksum": "abc123",
          "metadata": {}
        }
      ],
      "lastPlayedTrackId": "track-uuid",
      "playbackStates": {
        "track-uuid": {
          "position": 1234.5,
          "duration": 3600.5,
          "updatedAt": "2025-11-03T16:00:00Z"
        }
      },
      "tags": ["fiction", "completed"]
    }
  ]
}
```

---

## 3. Remote Sync (CloudKit) - Optional

**File:** `/Users/senaca/projects/audiobook-player/AudiobookPlayer/CloudKitLibrarySync.swift`

### Configuration
**Disabled by Default:**
```swift
// Info.plist
<key>CloudKitSyncEnabled</key>
<false/>
```

To enable, set to `<true/>` and add CloudKit capability in Xcode.

### CloudKit Storage

**Record Type:** `Collection`
**Database:** Private CloudKit database

**Fields in CKRecord:**
- `recordID`: UUID string of collection
- `payload`: JSON-encoded `AudiobookCollection` (as binary data)
- `schemaVersion`: Current version (2)
- `updatedAt`: Collection modification timestamp

### Sync Strategy

**Two-way Sync with Timestamp Resolution:**
1. Load local collections
2. Fetch remote collections from CloudKit
3. Merge based on `updatedAt` timestamp
4. Newer version wins
5. Older local version uploads to remote
6. Collections with no remote copy upload to remote

**Merge Logic:**
```swift
if remote.updatedAt > local.updatedAt {
    Use remote version
} else if local.updatedAt > remote.updatedAt {
    Upload local to remote
}
```

### When CloudKit Sync Happens
- Automatic on app launch (if enabled)
- Automatic on `save()` call
- Automatic on `delete()` call
- Failures are silently ignored (local data is authoritative offline)

---

## 4. In-Memory Playback State

**File:** `/Users/senaca/projects/audiobook-player/AudiobookPlayer/AudioPlayerViewModel.swift`

### Runtime Properties

```swift
@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false            // Current playback state
    @Published var currentTime: Double = 0      // Current position in seconds
    @Published var duration: Double = 0         // Track duration in seconds
    @Published var statusMessage: String?       // User-facing status
    @Published var activeCollection: AudiobookCollection?  // Currently playing collection
    @Published var currentTrack: AudiobookTrack?           // Currently playing track
    
    private var playlist: [AudiobookTrack] = []            // Current playlist (sorted)
    private var player: AVPlayer?                          // AVFoundation player
    private var currentToken: BaiduOAuthToken?             // Auth token for Baidu streams
}
```

### Persistence Triggers

**When Playback Progress is Saved:**
1. Player updates `currentTime` every 0.5 seconds via `addPeriodicTimeObserver()`
2. UI can call `LibraryStore.recordPlaybackProgress()` to persist
3. Called from:
   - `ContentView.PlayingTabView` - slider updates
   - `CollectionDetailView` - track selection
   - Auto-update on periodic timer in view layer

### No In-Memory Caching Beyond Playback
- Loaded collections are stored in `LibraryStore.collections`
- Loaded tokens are in `BaiduAuthViewModel.token`
- Runtime state (current time, etc.) is **NOT** cached to disk
- Only episodic saves when progress changes significantly

---

## 5. Configuration & Settings

### Baidu OAuth Configuration
**Source:** `Info.plist`

```plist
<key>BaiduClientId</key>
<string>37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4</string>
<key>BaiduClientSecret</key>
<string>cUTK7dZv9HCTCuNuD362xGZqueyGmwPD</string>
<key>BaiduRedirectURI</key>
<string>bd120615406://oauth-callback</string>
<key>BaiduScope</key>
<string>basic,netdisk</string>
<key>CloudKitSyncEnabled</key>
<false/>
```

**Loaded at Runtime:**
```swift
// In BaiduOAuth.swift
static func loadFromMainBundle() throws -> BaiduOAuthConfig {
    guard let bundle = Bundle.main.infoDictionary else {
        throw Error.missingConfiguration
    }
    
    let clientId = try value(for: "BaiduClientId")
    let clientSecret = try value(for: "BaiduClientSecret")
    // ... etc
}
```

**No UserDefaults or Preferences:**
- Application does NOT use UserDefaults
- Configuration is baked into Info.plist
- No user preferences stored
- Could be added in future for features like:
  - Speed preferences
  - Sleep timer duration
  - Sort order
  - UI theme

### URL Scheme Configuration
```plist
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.senaca.AudiobookPlayer.baidu</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>bd120615406</string>
            <string>com.wdh.audiobook</string>
        </array>
    </dict>
</array>
```

Allows OAuth redirect: `bd120615406://oauth-callback?code=...&state=...`

---

## 6. Data Models Summary Table

| Model | File | Purpose | Persisted | Storage |
|-------|------|---------|-----------|---------|
| `BaiduOAuthToken` | BaiduOAuth.swift | OAuth2 access token | Yes | Keychain |
| `BaiduOAuthConfig` | BaiduOAuth.swift | OAuth2 configuration | No (Info.plist) | Info.plist |
| `AudiobookCollection` | LibraryModels.swift | Audiobook metadata | Yes | JSON file |
| `AudiobookTrack` | LibraryModels.swift | Track metadata | Yes | JSON file |
| `TrackPlaybackState` | LibraryModels.swift | Playback progress | Yes | JSON file |
| `CollectionCover` | LibraryModels.swift | Cover art reference | Yes | JSON file |
| `LibraryFile` | LibraryStore.swift | Root container | Yes | JSON file |
| `AVPlayer` | AudioPlayerViewModel.swift | Audio playback | No | In-memory only |

---

## 7. Data Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    iOS App (Foreground)                  │
│                                                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Baidu OAuth Flow                                  │   │
│  │ 1. User taps "Sign In"                            │   │
│  │ 2. ASWebAuthenticationSession launches browser   │   │
│  │ 3. User approves in Baidu                        │   │
│  │ 4. Redirect URI callback received                │   │
│  │ 5. Token exchanged via HTTPS POST                │   │
│  │ 6. Token saved to Keychain                       │   │
│  └──────────────────────────────────────────────────┘   │
│                            │                              │
│                    ┌───────▼────────┐                    │
│                    │  Keychain      │                    │
│                    │ (Encrypted)    │                    │
│                    └────────────────┘                    │
│                                                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Collection Management                             │   │
│  │ 1. User creates collection from Baidu folder     │   │
│  │ 2. Scans folder for audio files                  │   │
│  │ 3. Builds AudiobookCollection object             │   │
│  │ 4. Calls LibraryStore.save()                     │   │
│  │ 5. Async persistence to JSON                     │   │
│  └──────────────────────────────────────────────────┘   │
│                            │                              │
│                    ┌───────▼────────────────────┐        │
│                    │ ~/Library/Application      │        │
│                    │ Support/AudiobookPlayer/   │        │
│                    │ library.json               │        │
│                    └────────────────────────────┘        │
│                                                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Playback & Progress Tracking                      │   │
│  │ 1. User selects track in collection              │   │
│  │ 2. AudioPlayerViewModel loads collection         │   │
│  │ 3. Audio streams from Baidu via HTTP             │   │
│  │ 4. Playback position updated every 0.5s          │   │
│  │ 5. User progress saved (position ≥5s change)     │   │
│  │ 6. playbackStates[trackId] updated in memory     │   │
│  │ 7. Async persist to JSON                         │   │
│  └──────────────────────────────────────────────────┘   │
│                                                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Optional CloudKit Sync (Disabled by Default)      │   │
│  │ 1. LibraryStore.load() checks CloudKitEnabled    │   │
│  │ 2. If enabled, fetches remote collections        │   │
│  │ 3. Merges by timestamp (newer wins)              │   │
│  │ 4. On save/delete, syncs to iCloud               │   │
│  │ 5. Failures silently ignored                      │   │
│  └──────────────────────────────────────────────────┘   │
│                            │                              │
│                    ┌───────▼────────┐                    │
│                    │  CloudKit       │                    │
│                    │  (iCloud)       │                    │
│                    └────────────────┘                    │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

---

## 8. Security & Privacy Considerations

### Strengths
1. **Keychain for tokens:** Secure, encrypted, OS-protected
2. **No hardcoded tokens:** Configuration loaded from Info.plist
3. **Bookmarks for local files:** Files accessed via Security Framework, respects sandbox
4. **No logging of sensitive data:** Token values never logged

### Potential Improvements
1. **Token refresh:** Currently requires manual re-sign-in after expiry
2. **Encryption at rest:** JSON file not encrypted (but in app sandbox)
3. **API credentials in Info.plist:** Visible in binary/IPA (acceptable for OAuth public apps)
4. **No biometric lock:** Token access not protected by Face ID / Touch ID
5. **Local file bookmarks:** Data remains valid even after app uninstall (acceptable for local files)

### File Locations
- **JSON Library:** Readable/writable by app only, in app sandbox
- **Keychain:** Protected by device passcode/biometric
- **Baidu Tokens:** Should never be cached to disk except in Keychain

---

## 9. Testing & Verification

### How to Inspect Stored Data

**View Library JSON (macOS):**
```bash
cat ~/Library/Application\ Support/AudiobookPlayer/library.json | python3 -m json.tool
```

**View Keychain (macOS):**
```bash
security find-generic-password -s "com.wdh.audiobook.baidu.oauth" -a "baidu_oauth_token"
```

**View in iOS Simulator:**
```bash
# Find app sandbox
xcrun simctl get_app_container booted com.senaca.AudiobookPlayer data

# View library.json
cat "<path>/Library/Application Support/AudiobookPlayer/library.json"

# View Keychain (requires Xcode debugging)
# Use Xcode Debugger → po NSFileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
```

---

## 10. Summary of Storage Mechanisms

| Component | Storage Type | Location | Purpose | Persistence |
|-----------|--------------|----------|---------|------------|
| **OAuth Token** | Keychain | Secure enclave | Baidu authentication | Until expiry/sign-out |
| **Library Data** | JSON File | App sandbox | Collection & track metadata | Indefinite |
| **Playback Progress** | JSON File | App sandbox | Track position tracking | Per-track basis |
| **OAuth Config** | Info.plist | Binary | App credentials | At compile time |
| **URL Scheme** | Info.plist | Binary | OAuth redirect | At compile time |
| **CloudKit (opt) ** | CloudKit | iCloud | Remote sync | If enabled |
| **Current Playback** | In-memory | RAM | Active playback state | Session only |

---

## 11. File Paths Reference

**All relative to app sandbox root:**

```
~/Library/Application Support/AudiobookPlayer/
├── library.json                 # Main library data file
└── (contains all collections, tracks, playback states)

Keychain Entries:
├── Service: com.wdh.audiobook.baidu.oauth
└── Account: baidu_oauth_token  # JSON-encoded BaiduOAuthToken

Info.plist Keys:
├── BaiduClientId
├── BaiduClientSecret
├── BaiduRedirectURI
├── BaiduScope
├── CloudKitSyncEnabled
└── CFBundleURLTypes (for OAuth callback)
```

---

## 12. Recommendations for Future Development

### 1. User Preferences (Suggested Storage)
```swift
@AppStorage("playbackSpeed") var speed: Double = 1.0
@AppStorage("sleepTimer") var sleepTimerMinutes: Int = 0
@AppStorage("darkMode") var isDarkModeEnabled: Bool = false

// Uses UserDefaults under the hood (domain: group.com.senaca.AudiobookPlayer)
```

### 2. Token Refresh Implementation
```swift
// Add refresh_token handling to BaiduOAuthService
// Check token expiry before API calls
// Automatically refresh if expired
```

### 3. Database Migration Path
Current: JSON file
Future options: SwiftData, Core Data (if need for complex queries)

### 4. CloudKit Best Practices
- Add conflict resolution for simultaneous edits
- Implement retry logic for sync failures
- Add sync status indicator to UI
- Cache CloudKit results locally to reduce API calls

### 5. Backup & Restore
- Export library to JSON file (data sharing)
- Import from exported JSON
- CloudKit provides automatic backup if enabled

---

## Conclusion

The audiobook player uses a **pragmatic, multi-layered approach** to data storage:

1. **Secure authentication** via Keychain (OAuth tokens)
2. **Efficient local persistence** via JSON file (collections, tracks, progress)
3. **Optional cloud sync** via CloudKit (for cross-device access)
4. **Minimal runtime state** kept in memory (only active playback)

This design balances **security, simplicity, and functionality** without introducing unnecessary complexity. The architecture is well-suited for the app's current scope and can easily scale to support additional features like user preferences, offline downloads, or multi-user scenarios.
