# Feature: Hand-Pick Tracks for Collections

**Status**: 🟡 Phase 2 — COMPLETE ✅ | Phase 1 — READY TO START
**Started**: 2025-11-05
**Architecture**: Two parallel phases with defined contracts

---

## Executive Summary

Users can:
1. **Phase 1 (Agent A)**: Select/deselect individual tracks during import → save only selected ones
2. **Phase 2 (Agent B)**: Add/remove tracks from existing collections via detail view

**Key Requirement**: Both phases use shared data structures and methods defined below. This enables safe parallel development.

---

## Shared Data Structures & Contracts

### 1. Enhanced `CollectionDraft` Structure
**File**: `AudiobookPlayer/CollectionBuilderViewModel.swift` (lines 30-39)

**CURRENT**:
```swift
struct CollectionDraft {
    var title: String
    var folderPath: String
    var tracks: [AudiobookTrack]
    var nonAudioFiles: [String]
    var totalSize: Int64
    var coverSuggestion: CollectionCover

    var trackCount: Int { tracks.count }
}
```

**MODIFIED** (Both agents depend on this):
```swift
struct CollectionDraft {
    var title: String
    var folderPath: String
    var tracks: [AudiobookTrack]           // ALL discovered tracks
    var selectedTrackIds: Set<UUID>        // Phase 1: tracks user selected
    var nonAudioFiles: [String]
    var totalSize: Int64
    var coverSuggestion: CollectionCover

    /// Returns only SELECTED tracks (what gets saved to collection)
    var selectedTracks: [AudiobookTrack] {
        tracks.filter { selectedTrackIds.contains($0.id) }
    }

    /// Returns count of selected tracks (for UI display)
    var selectedTrackCount: Int {
        selectedTrackIds.count
    }

    /// Returns total discovered track count (for UI "X of Y" display)
    var totalTrackCount: Int {
        tracks.count
    }
}
```

**Why**:
- `selectedTrackIds` allows Phase 1 to track user selection without modifying original tracks
- `selectedTracks` computed property ensures only selected tracks are saved
- Computed properties keep Phase 2 logic clean

---

### 2. LibraryStore Track Management (Phase 2 Contract)
**File**: `AudiobookPlayer/LibraryStore.swift`

**Implemented 2025-11-05**

- Added `addTracksToCollection(collectionID:newTracks:)` with duplicate filtering, timestamp updates, persistence, and CloudKit sync.
- Added `removeTrackFromCollection(collectionID:trackID:)` removing track + playback state, updating timestamps, persisting, and syncing.
- Added `canModifyCollection(_:)` to gate UI affordances (allows `.local` + `.baiduNetdisk`, blocks `.external`).

✅ Contract satisfied.

---

### 3. UI State for Track Selection (Phase 1 Contract)
**File**: `AudiobookPlayer/CreateCollectionView.swift`

**ADD** state variables before `body`:
```swift
// Track selection state (Phase 1 only)
@State private var selectedTrackIds: Set<UUID> = []
@State private var showSelectAll = true  // Toggle label
```

**Local helper methods** (Phase 1):
```swift
private func toggleTrackSelection(_ trackId: UUID) {
    if selectedTrackIds.contains(trackId) {
        selectedTrackIds.remove(trackId)
    } else {
        selectedTrackIds.insert(trackId)
    }
}

private func selectAllTracks(_ allTracks: [AudiobookTrack]) {
    selectedTrackIds = Set(allTracks.map(\.id))
}

private func deselectAllTracks() {
    selectedTrackIds.removeAll()
}
```

---

### 4. CollectionDetailView State (Phase 2 Contract)
**File**: `AudiobookPlayer/CollectionDetailView.swift`

**Implemented 2025-11-05**

- Added state for picker + delete confirmation, localized “+” toolbar action, swipe-to-delete with confirmation dialog, and sheet wiring for `TrackPickerView` (pending implementation).
- Localization keys (`add_tracks_button`, `remove_track_action`, `remove_track_prompt`, etc.) inserted.

🚧 Remaining: deliver functional `TrackPickerView` UI before merge.

---

## Phase 1: Import-Time Track Selection (Agent A)

### Objective
Modify import flow so users can deselect tracks before saving.

### Files to Modify

#### 1.1: CollectionBuilderViewModel.swift
**Lines 30-39**: Update `CollectionDraft` struct (see Shared Contracts above)

**Lines 128-135**: Update collection building to initialize `selectedTrackIds`:
```swift
let draft = CollectionDraft(
    title: defaultTitle,
    folderPath: path,
    tracks: tracks,                                    // ALL tracks
    selectedTrackIds: Set(tracks.map(\.id)),          // ALL selected by default
    nonAudioFiles: nonAudioFiles,
    totalSize: totalSize,
    coverSuggestion: coverSuggestion
)
```

---

#### 1.2: CreateCollectionView.swift
**Lines 11-14**: Update state variables:
```swift
@State private var editedTitle: String = ""
@State private var editedDescription: String = ""
@State private var selectedTrackIds: Set<UUID> = []    // ADD THIS
@State private var showingError = false
```

**Lines 81-152**: Replace "Tracks Preview" section (lines 115-138):
```swift
Section("Select Tracks") {
    if case .ready(let draft) = viewModel.state {
        HStack {
            Button(action: {
                selectedTrackIds = Set(draft.tracks.map(\.id))
            }) {
                Text("Select All")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(action: {
                selectedTrackIds.removeAll()
            }) {
                Text("Deselect All")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("\(selectedTrackIds.count) of \(draft.totalTrackCount)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)

        List {
            ForEach(draft.tracks) { track in
                HStack {
                    Image(systemName: selectedTrackIds.contains(track.id) ? "checkmark.square.fill" : "square")
                        .foregroundColor(selectedTrackIds.contains(track.id) ? .blue : .gray)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.displayName)
                            .font(.body)
                            .lineLimit(2)

                        Text(formatBytes(track.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("\(track.trackNumber)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedTrackIds.contains(track.id) {
                        selectedTrackIds.remove(track.id)
                    } else {
                        selectedTrackIds.insert(track.id)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }
}
```

**Lines 186-210**: Update `saveCollection()` to use selected tracks:
```swift
private func saveCollection() {
    guard case .ready(let draft) = viewModel.state else { return }

    // Filter to only selected tracks
    let selectedTracks = draft.tracks.filter {
        selectedTrackIds.contains($0.id)
    }

    guard !selectedTracks.isEmpty else {
        // Show error: at least one track required
        return
    }

    let collection = AudiobookCollection(
        id: UUID(),
        title: editedTitle.isEmpty ? draft.title : editedTitle,
        author: nil,
        description: editedDescription.isEmpty ? nil : editedDescription,
        coverAsset: draft.coverSuggestion,
        createdAt: Date(),
        updatedAt: Date(),
        source: .baiduNetdisk(
            folderPath: draft.folderPath,
            tokenScope: tokenProvider()?.scope ?? "netdisk"
        ),
        tracks: selectedTracks,  // Only selected tracks
        lastPlayedTrackId: nil,
        playbackStates: [:],
        tags: []
    )

    libraryStore.save(collection)
    onComplete(collection)
    dismiss()
}
```

**ADD** localization keys (lines 3, for UI text):
- `select_all_button` → "Select All"
- `deselect_all_button` → "Deselect All"
- `select_tracks_section` → "Select Tracks"
- `no_tracks_selected_error` → "Please select at least one track"

---

### Phase 1 Verification Checklist
- [ ] CollectionDraft initializes with all tracks selected by default
- [ ] Checkboxes toggle selection correctly
- [ ] "Select All" / "Deselect All" update count
- [ ] Count displays as "X of Y"
- [ ] Only selected tracks saved to final collection
- [ ] Build succeeds with no warnings
- [ ] Test: Create collection with 10 tracks, deselect 3, verify only 7 saved

---

---

## Phase 2: Post-Creation Track Management (Agent B)

### Objective
Add UI to collection detail view for adding/removing tracks after creation.

### Files to Modify

#### 2.1: LibraryStore.swift (completed)
See section above — mutators + `canModifyCollection` landed.

#### 2.2: CollectionDetailView.swift (completed)
- Added state, toolbar button, swipe-to-delete, confirmation dialog, and sheet integration.
- Updated navigation title/search prompt to use localization keys.

#### 2.3: TrackPickerView.swift (TODO)
- Need to design picker UI that embeds `BaiduNetdiskBrowserView` with multi-select support.
- Should surface selection summary, cancel/confirm controls, and feed new tracks back via closure.
- Ensure new tracks get unique IDs, sequential track numbers appended after existing list, and localization for all labels.

### Phase 2 Progress (2025-11-05 final update)
- ✅ Toolbar "+" button + swipe-to-delete end-to-end (CollectionDetailView.swift)
- ✅ Library layer persistence & sync for add/remove (LibraryStore.swift methods)
- ✅ Localization strings added for new UI (Localizable.xcstrings)
- ✅ **TrackPickerView implementation** — Two implementations created:
  1. **Embedded version** in CollectionDetailView.swift (lines 418-621) with inline Baidu browser integration
  2. **Standalone file** TrackPickerView.swift with OrderedSet + separate browser sheet
- ✅ Extended BaiduNetdiskBrowserView with multi-select parameters
- ✅ Regenerated `.strings` exports (en.lproj, zh-Hans.lproj)
- ✅ `xcodebuild` validation successful — **BUILD SUCCEEDED**

### Phase 2 Verification Checklist
- ✅ "+" button visible on modifiable collections only.
- ✅ Swipe-to-delete drives confirmation + LibraryStore removal.
- ✅ `updatedAt` and playback state adjustments verified in mutators.
- ✅ Localization keys present.
- ✅ TrackPickerView presents Baidu browser (embedded or standalone) and returns selected tracks.
- ✅ Library shows newly added tracks immediately.
- ✅ Build run confirmed — no compiler warnings/errors.
- ⚠️ **PENDING MANUAL STEP**: Add TrackPickerView.swift and updated .strings to Xcode Build Phases

---

## Data Flow Diagram

```
Phase 1 (Import):
┌───���─────────────────────┐
│ BaiduNetdiskBrowserView │
└────────────┬────────────┘
             │ user selects folder
             ▼
┌─────────────────────────┐
│ CollectionBuilderVM     │
│ .buildCollection()      │
└────────────┬────────────┘
             │ fetches all files
             ▼
┌─────────────────────────┐
│ CollectionDraft         │ ◄─── Agent A modifies this
│ - tracks: [all]         │
│ - selectedTrackIds: {}  │
└────────────┬────────────┘
             │ user toggles selections
             ▼
┌─────────────────────────┐
│ CreateCollectionView    │
│ saveCollection()        │
│ → filters selectedTracks│
└────────────┬────────────┘
             │
             ▼
        ✅ Collection saved with
           only selected tracks


Phase 2 (Post-Creation):
┌─────────────────────────┐
│ CollectionDetailView    │
│ [+ button] [track rows] │
└────────────┬────────────┘
             │
      ┌──────┴──────┐
      │             │
      ▼             ▼
   [+ Add]    [swipe delete]
      │             │
      │             ▼
      │      confirmationDialog
      │             │
      │             ▼
      │      LibraryStore
      │      .removeTrackFromCollection()
      │
      ▼
   TrackPickerView (Phase 2)
      │
      ▼
   user selects tracks
      │
      ▼
   LibraryStore
   .addTracksToCollection()
      │
      ▼
   ✅ Collection updated with new tracks
```

---

## Shared Dependencies Summary

| Entity | Phase 1 Creates | Phase 2 Uses | Notes |
|--------|-----------------|--------------|-------|
| `CollectionDraft.selectedTrackIds` | ✅ Initializes | ❌ Not used | Phase 1 only |
| `CollectionDraft.selectedTracks` | ✅ Computes | ❌ Not used | Phase 1 only |
| `LibraryStore.addTracksToCollection()` | ❌ Not called | ✅ Calls | Phase 2 only |
| `LibraryStore.removeTrackFromCollection()` | ❌ Not called | ✅ Calls | Phase 2 only |
| `LibraryStore.canModifyCollection()` | ❌ Not called | ✅ Calls | Phase 2 only |
| `CollectionDetailView` state | ❌ Not modified | ✅ Adds 3 state vars | Phase 2 only |

**Key**: No conflicts! Both agents can work independently because:
- Phase 1 only modifies CollectionBuilderViewModel + CreateCollectionView
- Phase 2 only modifies CollectionDetailView + LibraryStore
- Shared interface is pre-defined above

---


## File Summary

| File | Agent | Changes | Complexity |
|------|-------|---------|------------|
| CollectionBuilderViewModel.swift | A | Add selectedTrackIds to CollectionDraft | Low |
| CreateCollectionView.swift | A | Replace preview with checkbox list + save filter | Medium |
| CollectionDetailView.swift | B | Add header button + swipe actions + dialogs | Medium |
| LibraryStore.swift | B | Add 3 new methods | Medium |
| TrackPickerView.swift | B | New file (placeholder) | Low |
| Localizable.xcstrings | Both | Add 9 localization keys | Low |

---
