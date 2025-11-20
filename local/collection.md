# Audiobook Collections Architecture

**Date**: 2025-11-03
**Status**: ✅ Core implementation complete – ready for testing

## Goals
- Make the Library tab the landing screen, listing saved audiobook collections.
- Move Baidu Cloud sign-in/browsing into a tab for 'sources' so importing is optional friction.
- Allow users to build a collection from a Baidu Netdisk folder (future: local files, other cloud providers).
- Persist collections locally with metadata (title, tracks, cover art, source information) so they survive reinstalls.

## High-Level UX

| Tab | Purpose | Key Views |
| --- | --- | --- |
| **Library** (default) | Browse & play saved collections | `LibraryView` → list of collections, quick actions for Continue Listening & Manage |
| **Import** | select Baidu(which is authented in source tab), browse Netdisk, trigger collection creation | `BaiduImportView` wrapping existing auth + browser; future importers will plug into this tab |

### Library Tab Flow
1. App launches into `LibraryView`, backed by `LibraryStore` (ObservableObject).
2. Collections render as cards showing cover, title, track count, and last played progress.
3. Tapping a card hands the collection to `AudioPlayerViewModel.loadCollection(_:)`.
4. Empty state explains how to add the first collection and links to the Import tab.

### Import via Baidu Netdisk Flow
1. User opens Import tab, signs in if necessary.
2. `BaiduNetdiskBrowserView` now exposes a **Use This Folder** toolbar action.
3. Selecting a folder pushes `CreateCollectionView` (sheet) which:
   - Shows spinner while `CollectionBuilderViewModel` fetches the folder tree.
   - Lists detected audio tracks, non-audio files, total size, and warnings (e.g., >N files, empty).
   - Lets user rename the collection, choose/edit cover art placeholder, and confirm.
4. On confirm, `LibraryStore.save(collection:)` persists the new collection, broadcasts via `@Published`.
5. Optionally auto-select the new collection in Library tab for immediate playback.

## Data Model

```swift
struct TrackPlaybackState: Codable, Equatable {
    var position: TimeInterval
    var duration: TimeInterval?
    var updatedAt: Date
}

struct AudiobookCollection: Identifiable, Codable, Equatable {
    enum Source: Codable, Equatable {
        case baiduNetdisk(folderPath: String, tokenScope: String)
        case local(directoryBookmark: Data)
        case external(description: String)
    }

    let id: UUID
    var title: String
    var author: String?
    var description: String?
    var coverAsset: CollectionCover
    var createdAt: Date
    var updatedAt: Date
    var source: Source
    var tracks: [AudiobookTrack]
    var lastPlayedTrackId: UUID?
    var playbackStates: [UUID: TrackPlaybackState]
    var tags: [String]
}

struct AudiobookTrack: Identifiable, Codable, Equatable {
    enum Location: Codable, Equatable {
        case baidu(fsId: Int64, path: String)
        case local(urlBookmark: Data)
        case external(url: URL)
    }

    let id: UUID
    var displayName: String
    var filename: String
    var location: Location
    var fileSize: Int64
    var duration: TimeInterval?
    var trackNumber: Int
    var checksum: String?
    var metadata: [String: String]
}

struct CollectionCover: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case solid(colorHex: String)
        case image(relativePath: String) // Stored in Application Support images/
        case remote(url: URL)
    }

    var kind: Kind
    var dominantColorHex: String?
}
```

### Extensibility Notes
- `AudiobookCollection.Source` allows future importers (e.g., Google Drive) without schema changes.
- `AudiobookTrack.Location` abstracts file location: streaming vs. local caching vs. future downloads.
- Keep optional metadata dictionary to store per-provider extras (album, narrator, etc.).

## LibraryStore Persistence

- File location: `~/Library/Application Support/AudiobookPlayer/library.json`
- Structure:
  ```json
  {
    "schemaVersion": 2,
    "collections": [ ... ]
  }
  ```
- `LibraryStore` responsibilities:
  - `@Published var collections: [AudiobookCollection]`
  - `func save(_ collection: AudiobookCollection)` – upserts by `id`
  - `func delete(_ collection: AudiobookCollection)`
  - `func collection(forPath:)` – query by source path for dedupe
  - Writes use background queue + atomic replace (write temp file then move)
  - Provides `load()` on init; transparently migrates legacy v1 files (`lastPlaybackPosition`) into per-track states
  - When CloudKit is available, automatically merges with the user's private database and uploads local changes
- Cover images stored separately under `Application Support/covers/<collectionID>.jpg`. Reference path via `CollectionCover.Kind.image`.
- Logging: `~/Library/Logs/AudiobookPlayer/library.log` via simple `os_log` wrapper for diagnostics.

## Collection Builder

### ✅ Implementation Complete

**Files Created:**
- `CollectionBuilderViewModel.swift` (`AudiobookPlayer/CollectionBuilderViewModel.swift`)
- `CreateCollectionView.swift` (`AudiobookPlayer/CreateCollectionView.swift`)

**Features Implemented:**
- ✅ Async recursive directory scanning from Baidu Netdisk
- ✅ Audio file filtering: `["mp3","m4a","m4b","aac","flac","wav","opus","ogg"]`
- ✅ Sort with `localizedStandardCompare`
- ✅ Validation: Empty folders, max 500 tracks, expired tokens
- ✅ Progress updates (0.0…1.0) during scan
- ✅ Auto-generated gradient cover art (hash-based color)
- ✅ Track count, cumulative size, non-audio file listing
- ✅ 10-level depth limit to prevent infinite recursion
- ✅ Duplicate detection before launching builder (prompts to view existing collection)

**API Extensions:**
- `extension BaiduNetdiskClient`: `listAllFiles(in:token:)` helper method

### Requirements
- ~~Input: `folderPath` + `BaiduOAuthToken`, `BaiduNetdiskClient`.~~ ✅
- ~~Fetch directory with pagination~~ ✅ (simplified: single page for now, TODO: full pagination)
- ~~Filter audio extensions~~ ✅
- ~~Sort with `localizedStandardCompare`~~ ✅
- ~~Compute totals~~ ✅
- ~~Validate~~ ✅
- ~~Emit progress updates~~ ✅

### View Model Sketch

```swift
@MainActor
final class CollectionBuilderViewModel: ObservableObject {
    enum State {
        case idle
        case loading(Double)      // progress
        case ready(CollectionDraft)
        case failed(CollectionBuildError)
    }

    @Published private(set) var state: State = .idle

    func buildCollection(
        from path: String,
        title: String?,
        tokenProvider: () -> BaiduOAuthToken?
    ) async
}
```

`CollectionDraft` captures computed tracks, non-audio files, totals, default title (folder name), and cover suggestion (first artwork found or autogenerated color).

## UI Components

### ✅ Implementation Status

- **`LibraryView`**: ✅ Uses `LibraryStore` to show cards and drives import flow.
  - ✅ Toolbar `Menu` keeps "Import" picker anchored below the button (per UX request)
  - ✅ Duplicate detection prompts to open existing collection or continue re-import
  - ✅ Launches `BaiduNetdiskBrowserView` and chains into `CreateCollectionView`
- **`CreateCollectionView`**: ✅ Implemented. Consumes `CollectionBuilderViewModel`.
  - ✅ Loading state – spinner with progress percentage
  - ✅ Ready state – editable form (title, description), track table (first 10), warnings
  - ✅ Error state – icon, message, retry and "Re-authenticate" button
  - ✅ Persists Baidu token scope from active session when saving collection
- **`BaiduNetdiskBrowserView`**: ✅ Enhanced
  - ✅ `onSelectFolder: (String) -> Void` callback support
  - ✅ Audio entries count badge on "Use This Folder" button
  - ✅ Button enabled only when audio files present
  - ✅ Resets selection state after callback fires

## Player Integration

- **`AudioPlayerViewModel`**: ✅ Streams Baidu Netdisk tracks in filename order, auto-advances the queue, and tracks the active collection/track for UI updates. Provides previous/next controls and exposes `prepareCollection(_:)` for detail views.
- **`CollectionDetailView`**: ✅ New searchable track screen with play/pause/next/previous controls, progress slider, and automatic library progress updates.
- **`LibraryView`**: ✅ Navigates into `CollectionDetailView` via `NavigationLink` while keeping the Baidu import flow and duplicate detection alerts.

## Storage & Future Services

- Consider wrapping JSON persistence in `FileBackedStore<T>` helper for reuse (collections today, future settings/profiles later).
- Keep schema versioned; on upgrade, migrate old keys or rebuild from snapshots.
- For large libraries, evaluate incremental saving (per collection file). V1 sticks to single JSON for simplicity.

## Work Log (2025-11-03)
- 🚧 Added `TrackPlaybackState` model and migrated collections (`schemaVersion` 2) to retain per-track resume positions alongside legacy fallback.
- 🚧 `LibraryStore.recordPlaybackProgress` now persists progress (5s granularity) and mirrors updates to CloudKit when available.
- 🚧 Introduced `CloudKitLibrarySync` actor (private DB) with automatic merge/upload during `LibraryStore.load()`; local JSON remains the cache.
- 🚧 CloudKit sync is gated by the new `CloudKitSyncEnabled` Info.plist flag (default `false`) to avoid entitlement crashes during local development.
- 🚧 `AudioPlayerViewModel` resumes from stored positions, seeks before autoplay, and updates progress via `CollectionDetailView` bindings.

### Immediate Testing Needed
- [x] Test import flow end-to-end in simulator with real Baidu account
- [x] Verify recursive folder scanning with nested directories
- [x] Test error handling (expired token, empty folders, network failures)
- [x] Validate progress tracking UI during long scans
- [x] Test collection persistence across app restarts

### Known Limitations (TODOs)
- Pagination: `listAllFiles` currently fetches only first page (TODO: implement full pagination for folders with >1000 items)
- Cover art: Only gradient-based covers implemented (future: user-picked images, extracted album art)
- Duration metadata: Not extracted (requires Baidu metadata API or file header inspection)

### Future Features
- Multi-device sync via iCloud or custom export
- Telemetry (opt-in analytics for import performance)
- Local files import support
- Other cloud providers (Google Drive, Dropbox, etc.)
- Custom cover art upload
- Track duration extraction

## Progress Log

### Session 2025-11-03 (Collection Builder Implementation)
**Implemented Files:**
- `CollectionBuilderViewModel.swift` - Async recursive folder scanner with progress tracking
  - Filters audio files: mp3, m4a, m4b, aac, flac, wav, opus, ogg
  - Validates: no audio files, max 500 tracks, expired tokens
  - Auto-generates gradient cover art from title hash
  - Recursive scanning with 10-level depth limit
- `CreateCollectionView.swift` - Import UI with three states (Loading/Ready/Error)
  - Editable title and description fields
  - Track preview (first 10) with file sizes
  - Non-audio file disclosure
  - Retry and re-authentication handling
- `LibraryView.swift` - Added import entry point that launches browser → builder flow
  - (Later session refined menu placement + duplicate handling)

**Build Status:** ✅ Success (warnings only, no errors)

### Session 2025-11-03 (Baidu Playback & Library Polish)
**Commits:**
- `6d64515` – “Add Baidu playback UI”
- `22752e2` – “Remove duplicate chevron in library rows”

**Highlights:**
- Added `CollectionDetailView` with searchable track list, inline playback controls, and progress updates that persist back into the library store.
- `AudioPlayerViewModel` now maintains an alphabetically sorted queue, streams Baidu Netdisk audio via signed download URLs, and supports prev/next autoplay.
- Library rows open the new detail view; Library UI uses the system chevron to avoid duplicate indicators.
- `BaiduNetdiskClient` exposes `downloadURL(forPath:token:)` to feed AVPlayer streaming.

**Notes:**
- Simulator build from CLI failed due to CoreSimulator permission issues; run in Xcode to validate.
- Playback currently streams directly; future work: caching/offline download, duration metadata, lock-screen controls.

**User Flow:**
1. Tap Import button (toolbar) → Menu appears below button
2. Select "Baidu Netdisk" → Browser sheet opens
3. Navigate folders → Audio count badge on "Use This Folder"
4. Select folder → CreateCollectionView scans recursively
5. Edit title/description → Review tracks and totals
6. "Add to Library" → Saves and optionally starts playback

### Session 2025-11-03 (Evening)
- Anchored the Library toolbar Import menu under the button (replacing bottom sheet).
- Wired Baidu folder selection into `CreateCollectionView` builder flow with duplicate detection.
- Persist Baidu token scope on saved collections and auto-load new collection into the player.
- Updated documentation / PROD.md with current workflow and outstanding test coverage.

### Session 2025-11-03 (Earlier)
- Added Sources tab + library import entry point, restored Netdisk search, and provided folder selection workflow with import prompt.

### Session 2025-11-02
- Implemented collection models, JSON-backed `LibraryStore`, and refactored root view into Library/Import tabs with placeholder library list.
- Updated app icon to audiobook-themed logo (book + headphones + streaming signal).

### Session 2025-11-04
- Removed bundled sample playback UI from `SourcesView` now that the Baidu import flow is primary.
- Deleted `test.mp3` asset and cleared the Xcode project reference to avoid missing-resource warnings.

## Implementation Sequence
1. [x] Implement data models and `LibraryStore`; inject into `AudiobookPlayerApp` environment.
2. [x] Refactor root navigation into `TabView` (Library + Import).
3. [x] Extend Baidu browser view/model with new callbacks and UI state.
4. [x] Build `CollectionBuilderViewModel` + `CreateCollectionView`.
5. [x] Wire flow end-to-end (Library → Sources → Browser → Builder → Library).
