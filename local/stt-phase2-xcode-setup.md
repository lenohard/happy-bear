# STT Phase 2 Xcode Build Target Setup

**Status**: ⚠️ Awaiting Manual Xcode Configuration
**Date**: 2025-11-08
**Action Required**: Add new files to Xcode build target

---

## Issue

Two new files have been created for the Phase 2 transcription UI implementation but need to be added to the Xcode project build target manually:

1. `AudiobookPlayer/TranscriptViewModel.swift` - State management for transcript viewing
2. `AudiobookPlayer/TranscriptViewerSheet.swift` - UI for viewing and searching transcripts

These files exist on the file system but are not yet included in the Xcode project's build target, which prevents compilation.

---

## Manual Xcode Configuration Required

### Step 1: Open Xcode Project
```bash
open AudiobookPlayer.xcodeproj
```

### Step 2: Add Files to Build Target

1. In Xcode, select the **AudiobookPlayer** target
2. Go to **Build Phases** tab
3. Expand **Compile Sources**
4. Click the **+** button to add files
5. Navigate to and select these files:
   - `AudiobookPlayer/TranscriptViewModel.swift`
   - `AudiobookPlayer/TranscriptViewerSheet.swift`
6. Ensure `AudiobookPlayer` target is checked
7. Click **Add**

### Step 3: Verify the Files Appear

After adding, you should see:
- TranscriptViewModel.swift
- TranscriptViewerSheet.swift

Both listed in the **Compile Sources** section under **Build Phases**.

### Step 4: Clean and Rebuild

In Xcode:
```
Cmd + Shift + K  (Clean Build Folder)
Cmd + B          (Build)
```

Or via command line:
```bash
xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -destination 'generic/platform=iOS Simulator' clean build
```

---

## After Xcode Setup: Enable Transcript Viewer Integration

Once the files are added to the build target and the build succeeds, uncomment the following in `AudiobookPlayer/CollectionDetailView.swift`:

```swift
// Add these state variables (lines 20-21)
@State private var trackForViewing: AudiobookTrack?
@State private var showTranscriptViewer = false

// Add this to the context menu (after line 280)
Button {
    trackForViewing = track
    showTranscriptViewer = true
} label: {
    Label(
        NSLocalizedString("view_transcript", comment: "View transcript menu item"),
        systemImage: "text.alignleft"
    )
}

// Add this sheet presentation (after line 147)
.sheet(isPresented: $showTranscriptViewer) {
    if let track = trackForViewing {
        TranscriptViewerSheet(trackId: track.id.uuidString, trackName: track.displayName)
    }
}
```

After uncommenting, the "View Transcript" option will appear in the track context menu (long-press on track).

---

## Why This Is Needed

According to Xcode project best practices (per project memory):
- New resource files and Swift files must be explicitly added to the build target
- Direct `pbxproj` editing risks file corruption
- Manual Xcode UI addition is the safe, recommended approach

---

## Testing After Setup

1. **Transcribe a track** using the existing "Transcribe Track" menu
2. **Long-press on the track** to see context menu
3. **Select "View Transcript"** (once integration is enabled)
4. **Search and navigate** through the transcript using the viewer

---

## Files Involved

| File | Status | Purpose |
|------|--------|---------|
| TranscriptViewModel.swift | ✅ Created | Manages transcript loading, searching, highlighting |
| TranscriptViewerSheet.swift | ✅ Created | UI for viewing transcript with segments and search |
| CollectionDetailView.swift | ⏸️ Partially Ready | Needs Xcode setup + uncomment integration |
| Localizable.xcstrings | ⏳ Pending | Add localization keys for transcript UI |

---

## Next Steps (After Xcode Setup)

1. Verify build succeeds with files in target
2. Add missing localization keys to `Localizable.xcstrings`
3. Generate `.strings` files from xcstrings
4. Test end-to-end: transcribe → view → search
5. Continue with Stage 2 (progress indicator)
