# Data Storage Architecture - Quick Reference Guide

## Storage Summary at a Glance

```
┌─────────────────────────────────────┐
│    AUDIOBOOK PLAYER DATA STORAGE    │
└─────────────────────────────────────┘

1. OAUTH TOKEN (Secure)
   ├─ Storage: Apple Keychain
   ├─ Service: com.wdh.audiobook.baidu.oauth
   ├─ Account: baidu_oauth_token
   ├─ File: BaiduTokenStore.swift
   └─ Lifecycle: Loaded on startup, cleared on sign-out

2. LIBRARY & METADATA (Local)
   ├─ Storage: JSON file in app sandbox
   ├─ Location: ~/Library/Application Support/AudiobookPlayer/library.json
   ├─ File: LibraryStore.swift, LibraryModels.swift
   └─ Format: Codable structs (pretty-printed JSON)

3. PLAYBACK PROGRESS (Persistent)
   ├─ Storage: Within library.json
   ├─ Structure: TrackPlaybackState objects
   ├─ Key: UUID-indexed playbackStates dictionary
   └��� Debounce: Only saves on 5+ second changes

4. OAUTH CONFIG (Static)
   ├─ Storage: Info.plist (compiled into binary)
   ├─ Keys: BaiduClientId, BaiduClientSecret, BaiduRedirectURI
   ├─ File: AudiobookPlayer/Info.plist
   └─ Loading: BaiduOAuthConfig.loadFromMainBundle()

5. CLOUDKIT SYNC (Optional)
   ├─ Storage: iCloud Private Database
   ├─ Status: Disabled by default (CloudKitSyncEnabled=false)
   ├─ File: CloudKitLibrarySync.swift
   └─ Trigger: Automatic on load/save/delete if enabled

6. PLAYBACK STATE (Runtime Only)
   ├─ Storage: In-memory (AudioPlayerViewModel)
   ├─ Content: Current track, position, duration
   ├─ File: AudioPlayerViewModel.swift
   └─ Persistence: Only via recordPlaybackProgress()
```

---

## Key File Locations

### Source Files
```
AudiobookPlayer/
├── BaiduTokenStore.swift           ← OAuth token persistence (Keychain)
├── BaiduOAuth.swift                ← OAuth service & token model
├── BaiduAuthViewModel.swift        ← Token loading/saving logic
├── LibraryStore.swift              ← Collection persistence (JSON file)
├── LibraryModels.swift             ← Data models (Collection, Track, State)
├── AudioPlayerViewModel.swift      ← Playback progress tracking
├── CloudKitLibrarySync.swift       ← Optional remote sync
├── Info.plist                      ← OAuth config & URL schemes
└── AudiobookPlayerApp.swift        ← App initialization
```

### Storage Paths
```
Keychain:
  Service: com.wdh.audiobook.baidu.oauth
  Account: baidu_oauth_token

File System:
  ~/Library/Application Support/AudiobookPlayer/library.json

CloudKit (if enabled):
  iCloud Private Database → Collection records
```

---

## Code Flow Examples

### 1. Loading Token on App Startup

**File:** `BaiduAuthViewModel.swift`

```swift
// 1. ViewController initializes BaiduAuthViewModel
let authVM = BaiduAuthViewModel()

// 2. Init calls loadPersistedToken()
private func loadPersistedToken() {
    do {
        if let stored = try tokenStore.loadToken(), !stored.isExpired {
            token = stored  // ✓ Loaded successfully
        } else {
            try? tokenStore.clearToken()  // Clear if expired
        }
    } catch {
        errorMessage = "Failed to load saved Baidu session."
    }
}

// 3. tokenStore (KeychainBaiduOAuthTokenStore) loads from Keychain
func loadToken() throws -> BaiduOAuthToken? {
    let query = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.wdh.audiobook.baidu.oauth",
        kSecAttrAccount: "baidu_oauth_token",
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
    ] as [String: Any]
    
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    // Decode JSON from Data
    return try decoder.decode(BaiduOAuthToken.self, from: data)
}
```

### 2. Saving a Library Collection

**File:** `LibraryStore.swift`

```swift
// 1. UI calls libraryStore.save(collection)
func save(_ collection: AudiobookCollection) {
    var updated = collections
    if let index = updated.firstIndex(where: { $0.id == collection.id }) {
        updated[index] = collection
    } else {
        updated.append(collection)
    }
    collections = updated  // Update @Published property
    persistCurrentSnapshot()  // Trigger async save
}

// 2. persistCurrentSnapshot() runs async on background
private func persistCurrentSnapshot() {
    let snapshot = LibraryFile(schemaVersion: 2, collections: collections)
    Task(priority: .utility) {
        do {
            try await persistence.save(snapshot)
        } catch {
            // Handle error
        }
    }
}

// 3. LibraryPersistence.save() writes to disk atomically
func save(_ file: LibraryFile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    
    let data = try encoder.encode(file)
    let tempURL = fileURL.appendingPathExtension("tmp")
    
    // Write to temp first (atomic safety)
    try data.write(to: tempURL, options: .atomic)
    
    // Move to final location
    try fileManager.moveItem(at: tempURL, to: fileURL)
}
```

### 3. Recording Playback Progress

**File:** `LibraryStore.swift` & UI

```swift
// 1. AudioPlayerViewModel observes playback
private func addPeriodicTimeObserver() {
    timeObserverToken = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
        queue: .main
    ) { [weak self] time in
        self.currentTime = time.seconds
    }
}

// 2. UI calls recordPlaybackProgress()
@EnvironmentObject var libraryStore: LibraryStore
Button("Skip Ahead") {
    audioPlayer.skipForward(by: 30)
    libraryStore.recordPlaybackProgress(
        collectionID: collection.id,
        trackID: track.id,
        position: audioPlayer.currentTime,
        duration: audioPlayer.duration
    )
}

// 3. recordPlaybackProgress() updates playbackStates
func recordPlaybackProgress(
    collectionID: UUID,
    trackID: UUID,
    position: TimeInterval,
    duration: TimeInterval?
) {
    guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
    
    var collection = collections[index]
    let clampedPosition = max(0, position)
    let didChangePosition = abs(state.position - clampedPosition) >= 5  // Debounce
    
    if !didChangePosition && !didChangeDuration {
        return  // Don't save if no significant change
    }
    
    collection.playbackStates[trackID] = TrackPlaybackState(
        position: clampedPosition,
        duration: duration,
        updatedAt: Date()
    )
    collection.lastPlayedTrackId = trackID  // Remember for resume
    
    collections[index] = collection
    persistCurrentSnapshot()  // Save to disk
}
```

### 4. Loading Collections on App Launch

**File:** `LibraryStore.swift`

```swift
// 1. LibraryStore initializes with autoLoadOnInit=true
@StateObject private var libraryStore = LibraryStore(autoLoadOnInit: true)

// 2. Calls load()
func load() async {
    do {
        let file = try await persistence.load()
        guard file.schemaVersion <= schemaVersion else {
            throw LibraryStoreError.unsupportedSchema(file.schemaVersion)
        }
        
        collections = file.collections.sorted { $0.updatedAt > $1.updatedAt }
        
        // Optional: trigger CloudKit sync
        if let syncEngine {
            await synchronizeWithRemote(using: syncEngine)
        }
    } catch {
        collections = []
        lastError = error
    }
}

// 3. LibraryPersistence.load() reads from disk
func load() throws -> LibraryFile {
    guard fileManager.fileExists(atPath: fileURL.path) else {
        return LibraryFile(schemaVersion: 1, collections: [])  // New app
    }
    
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LibraryFile.self, from: data)
}
```

---

## Data Model Hierarchy

```
LibraryFile (Root)
├── schemaVersion: Int
└── collections: [AudiobookCollection]
    ├── id: UUID
    ├── title: String
    ├── author: String?
    ├── source: Source
    │   ├── .baiduNetdisk(folderPath, tokenScope)
    │   ├── .local(directoryBookmark)
    │   └── .external(description)
    ├── tracks: [AudiobookTrack]
    │   ├── id: UUID
    │   ├── displayName: String
    │   ├── location: Location
    │   │   ├── .baidu(fsId, path)
    │   │   ├── .local(urlBookmark)
    │   │   └── .external(url)
    │   └── duration: TimeInterval?
    ├── lastPlayedTrackId: UUID?
    ├── playbackStates: [UUID: TrackPlaybackState]
    │   ├── position: TimeInterval
    │   ├── duration: TimeInterval?
    │   └── updatedAt: Date
    └── tags: [String]
```

---

## Thread Safety

### Main Actor Enforcement
```swift
@MainActor
final class LibraryStore: ObservableObject { }

@MainActor
final class AudioPlayerViewModel: ObservableObject { }

@MainActor
final class BaiduAuthViewModel: ObservableObject { }
```
- All UI updates must happen on main thread
- SwiftUI re-renders on `@Published` changes

### Background Persistence
```swift
Task(priority: .utility) {
    try await persistence.save(snapshot)
}
```
- File I/O runs on background thread
- Actor-isolated `LibraryPersistence` prevents concurrent access

---

## Error Handling

### Token Errors
```swift
enum TokenStoreError: Error {
    case unhandledStatus(OSStatus)
}
// Maps to Security Framework error codes
```

### Library Errors
```swift
enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
}
```

### OAuth Errors
```swift
enum BaiduOAuthService.Error: LocalizedError {
    case missingConfiguration
    case missingConfigurationValue(key: String)
    case placeholderConfigurationValue(key: String)
    case invalidRedirectURI
    case missingCallbackScheme
    case userCancelled
    case invalidState
    case authorizationCodeMissing
    case tokenExchangeFailed(status: Int, message: String)
}
```

---

## Testing & Inspection

### View Stored Data

**Library JSON (macOS):**
```bash
cat ~/Library/Application\ Support/AudiobookPlayer/library.json | python3 -m json.tool
```

**Keychain (macOS):**
```bash
security find-generic-password -s "com.wdh.audiobook.baidu.oauth" -a "baidu_oauth_token"
```

**Xcode Debugger (iOS Simulator):**
```
- Set breakpoint in BaiduAuthViewModel.loadPersistedToken()
- po token (print token object)
- po libraryStore.collections (print collections)
```

---

## Key Implementation Details

### 1. Debouncing
Only saves playback progress if:
- Position changes by ≥5 seconds, OR
- Duration changes by ≥1 second
- Reduces unnecessary disk writes

### 2. Atomic File Operations
```swift
1. Encode to temporary .tmp file
2. Write with atomic flag
3. Delete old file (if exists)
4. Move .tmp to final location
```
Prevents corruption on crashes

### 3. Schema Versioning
```swift
schemaVersion: Int = 2
```
Supports future migrations:
- v1 → v2: Automatic upgrade on load
- v2 → v3: Will implement when needed

### 4. Token Expiry
```swift
var isExpired: Bool {
    Date() >= expiresAt
}
```
Automatically cleared on load if expired
Requires manual re-sign-in for refresh

### 5. Resume from Last Position
```swift
collection.lastPlayedTrackId  // Which track to play
playbackStates[trackId].position  // Where to seek to
```

---

## Summary Table

| Component | Storage | Size Limit | Thread-Safe | Encrypted |
|-----------|---------|-----------|------------|-----------|
| OAuth Token | Keychain | <1KB | Yes (Keychain) | Yes (OS) |
| Library (1000 collections) | JSON file | ~10MB | Yes (Actor) | No |
| Playback State | JSON file | Included in library | Yes (Actor) | No |
| Config | Info.plist | <5KB | N/A (static) | N/A |
| Current Playback | RAM | ~1MB | Yes (@MainActor) | N/A |
| CloudKit Records | iCloud | Unlimited | Yes (CKDatabase) | Yes (HTTPS) |

---

## Quick Checklist for Developers

When adding new data to persist:

- [ ] Define Codable struct in LibraryModels.swift
- [ ] Add field to AudiobookCollection or TrackPlaybackState
- [ ] Increment schemaVersion if incompatible
- [ ] Add migration logic if needed
- [ ] Call recordPlaybackProgress() or save() to persist
- [ ] Test load on app launch
- [ ] Verify JSON output looks correct
- [ ] Test CloudKit sync if applicable

When adding sensitive data:

- [ ] Use Keychain (via BaiduTokenStore pattern)
- [ ] Never log token values
- [ ] Never cache to JSON unless in Keychain
- [ ] Set appropriate access constraints
