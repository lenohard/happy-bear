# Bugs & Enhancements
2025-11-04 星期二

## ✅ Bug 6 – Recursive Search Toggle Not Working (FIXED)
**Status:** ✅ Completed (pending commit)
**Date:** 2025-11-04

### Problem
- The "Recursive Search" toggle in Baidu Netdisk search was not functioning correctly
- Users reported the toggle didn't work as expected
- This feature was causing confusion and poor user experience

### Solution
- **Removed the recursive search toggle entirely** from the UI to eliminate confusion
- **Always use Baidu's recursive API** for comprehensive search across all subdirectories
- This provides the most useful search behavior while simplifying the UI

### Changes Made
**Files Modified:**
- `AudiobookPlayer/BaiduNetdiskBrowserView.swift` - Removed recursive search toggle UI
- `AudiobookPlayer/BaiduNetdiskBrowserViewModel.swift` - Removed `useRecursiveSearch` property and hardcoded `recursive: true`

**Technical Details:**
```swift
// REMOVED from BaiduNetdiskBrowserView.swift:
Toggle("Recursive Search", isOn: $viewModel.useRecursiveSearch)
    .onChange(of: viewModel.useRecursiveSearch) { _ in
        if !searchTextTrimmed.isEmpty {
            viewModel.search(keyword: searchTextTrimmed)
        }
    }

// REMOVED from BaiduNetdiskBrowserViewModel.swift:
@Published var useRecursiveSearch = false

// UPDATED in BaiduNetdiskBrowserViewModel.swift:
recursive: true,  // Always use recursive search for comprehensive results
```

### User Experience Impact
- **Before**: Confusing toggle that didn't work properly, limited to current directory
- **After**: Seamless recursive search that finds files in all subdirectories
- **Benefit**: Users can find audio files anywhere in their Baidu Netdisk folder structure

### Rationale
- **Bug elimination**: Removes non-functional toggle that was causing user frustration
- **Enhanced functionality**: Recursive search is more useful for finding scattered audio files
- **Simplicity**: Clean UI with powerful default behavior
- **Performance**: Baidu's server-side recursive search is optimized for this use case

---

## ✅ Enhancement 4 – Improved Baidu Netdisk Search UX (COMPLETED)
**Status:** ✅ Completed (pending commit)
**Date:** 2025-11-04

### Changes
1. **Search on submit instead of per-character**
   - Search now triggers only when user presses Return/Search button (using `.onSubmit(of: .search)`)
   - Previously triggered on every keystroke, causing excessive API calls
   - Improves performance and reduces unnecessary network traffic

2. **Search all files by default**
   - Removed hardcoded audio-only filter (`category=2`)
   - Added new "Audio Files Only" toggle in Search Options
   - Users can now search for any file type and optionally filter to audio files
   - More flexible and matches general file browser expectations

3. **Updated UI text**
   - Search prompt changed from "Search audio files" → "Search files"
   - Added "Audio Files Only" toggle in Search Options section

### Technical Implementation
**Files Modified:**
- `AudiobookPlayer/BaiduNetdiskClient.swift`:
  - Added `audioOnly: Bool` parameter to `search()` method
  - Made category filter conditional based on `audioOnly` flag
  - Updated protocol `BaiduNetdiskListing`

- `AudiobookPlayer/BaiduNetdiskBrowserViewModel.swift`:
  - Added `@Published var audioOnly = false` (defaults to all files)
  - Pass `audioOnly` parameter to client.search()

- `AudiobookPlayer/BaiduNetdiskBrowserView.swift`:
  - Replaced `.onChange(of: searchText)` with `.onSubmit(of: .search)` for search trigger
  - Added "Audio Files Only" toggle in Search Options section
  - Both toggles (Recursive Search & Audio Files Only) trigger re-search when changed
  - Updated search prompt text

### API Changes
```swift
// Before:
func search(keyword: String, directory: String, recursive: Bool, token: BaiduOAuthToken)

// After:
func search(keyword: String, directory: String, recursive: Bool, audioOnly: Bool, token: BaiduOAuthToken)
```

### User Experience Improvements
| Aspect | Before | After |
|--------|--------|-------|
| Search Trigger | Every keystroke | Press Return/Search button |
| File Types | Audio only (hardcoded) | All files (with optional audio filter) |
| API Calls | Many (per character) | One (per search) |
| User Control | Limited | Full control via toggle |

---

## ✅ Bug 5 – App freezes when opening Baidu Netdisk browser (FIXED)
**Status:** ✅ Completed (pending commit)
**Date:** 2025-11-04

### Problem
- App freezes/hangs when trying to open Baidu Netdisk file browser
- UI becomes completely unresponsive
- Caused by infinite update loop in Enhancement 3 implementation

### Root Cause
The bug was introduced in Enhancement 3 when implementing iOS 16 compatibility:
- Used `onReceive(Just(searchText))` and `onReceive(Just(viewModel.useRecursiveSearch))` modifiers (lines 40 and 98-106 in `BaiduNetdiskBrowserView.swift`)
- `Just` publisher fires immediately on every view render
- Created recursive update cycle: state change → view render → onReceive fires → state change → repeat
- This infinite loop froze the main thread

### Solution
Replaced problematic `onReceive(Just(_))` modifiers with proper SwiftUI state observation:
- Changed `onReceive(Just(viewModel.useRecursiveSearch))` to `.onChange(of: viewModel.useRecursiveSearch)`
- Changed `onReceive(Just(searchText))` to `.onChange(of: searchText)`
- Removed unnecessary `import Combine` statement
- These `.onChange` modifiers only fire when the value actually changes, not on every render

**Files Modified:**
- `AudiobookPlayer/BaiduNetdiskBrowserView.swift` - Replaced `onReceive(Just(_))` with `.onChange(of:)` modifiers

### Technical Details
```swift
// ❌ BEFORE (causes infinite loop):
.onReceive(Just(searchText)) { newValue in
    // Fires on every render
}

// ✅ AFTER (fires only on change):
.onChange(of: searchText) { newValue in
    // Only fires when searchText actually changes
}
```

### Lessons Learned
1. ⚠️ **Avoid `onReceive(Just(_))` pattern** - it fires on every view render, not just on state changes
2. ✅ **Use `.onChange(of:)` for state observation** - only triggers when values actually change
3. ✅ **iOS 16 compatibility note**: `.onChange(of:)` works on iOS 16+ (no need for workarounds)
4. ⚠️ **Watch for infinite update cycles**: Always verify state observation patterns don't create render loops

### Testing
- ✅ Build succeeded without errors
- User should verify: Can now open Baidu Netdisk browser without freezing
- User should verify: Search and recursive toggle still work correctly

---

## ✅ Enhancement 3 – Baidu Netdisk Search Function Improvements (COMPLETED)
**Status:** ✅ Completed (commit `e6f6c2f`)
**Date:** 2025-11-04

### Problem
- Original search was client-side only (substring filtering on loaded entries)
- No support for recursive search across subdirectories
- Could only search files visible in the current folder
- No user control over search scope

### Solution
Implemented **server-side recursive search** using Baidu's native Search API:

**Files Modified:**
- `AudiobookPlayer/BaiduNetdiskClient.swift` - Added `search(keyword:directory:recursive:token:)` method
- `AudiobookPlayer/BaiduNetdiskBrowserViewModel.swift` - Added `@Published var useRecursiveSearch` toggle & `search(keyword:)` method
- `AudiobookPlayer/BaiduNetdiskBrowserView.swift` - Added "Search Options" UI with recursive toggle

**Key Features:**
- ✅ Server-side search using Baidu `/xpan/file?method=search` API endpoint
- ✅ Audio files only (category=2 filter)
- ✅ Recursive search option (searches subdirectories when enabled)
- ✅ Dynamic "Search Options" section in UI (only appears during search)
- ✅ Toggle to switch between current folder / recursive modes
- ✅ Auto re-search when toggle changes
- ✅ Clear search automatically when navigating folders
- ✅ iOS 16 compatible (using `.onChange(of:)` modifier after Bug 5 fix)

**Implementation Details:**
```swift
// Baidu Search API call structure:
// GET /rest/2.0/xpan/file?method=search&key=KEYWORD&dir=PATH&access_token=TOKEN
// Optional parameters:
// - recursion=1  (enables recursive search)
// - category=2   (audio files only)
```

### Benefits
| Aspect | Before | After |
|--------|--------|-------|
| Search Scope | Current folder only | Current folder + recursive |
| Source | Client-side filter | Server-side Baidu API |
| User Control | None | Toggle recursive on/off |
| File Types | All files | Audio only (category=2) |
| Performance | In-memory filtering | Server-side filtering |

### Testing Recommendations
1. Search for audio files in deeply nested directories with recursion enabled
2. Toggle recursive search on/off during active search (should re-search automatically)
3. Clear search and verify folder view is restored
4. Navigate into subdirectory during search (search should auto-clear)
5. Verify error handling when Baidu token expires

---

2025-11-03 星期一 23:49:26

## ✅ Bug 1 – UI Inconsistency: Sources tab add button & import button style (FIXED)
**Status:** ✅ Completed (commit `5c6258d`)

**Problem:**
- Sources tab had redundant add button that duplicated Library import functionality
- Import button styles were inconsistent between Sources and Library tabs
- No placeholder for future local files import feature

**Solution:**
- Removed the add button (plus.circle.fill) from SourcesView toolbar to eliminate redundancy
- Updated LibraryView import button to use plus.circle.fill icon with menu style matching previous SourcesView design
- Added Local Files section to Sources tab with disabled placeholder button for future implementation
- Added localization strings for new Local Files section in both English and Chinese
- Maintains import functionality while improving UI consistency across tabs

**Files Modified:**
- `AudiobookPlayer/LibraryView.swift`
- `AudiobookPlayer/SourcesView.swift`
- `AudiobookPlayer/Localizable.xcstrings`
- `AudiobookPlayer/en.lproj/Localizable.strings`
- `AudiobookPlayer/zh-Hans.lproj/Localizable.strings`

---

## 🔄 Open Issues

2. ✅ Lock screen controls & Bluetooth headset actions (FIXED - commit `e502ba5`)

3. ✅ Can't continue playing next track when a track finishes (FIXED - pending commit)

## ✅ Bug 2 – Lock screen controls & Bluetooth headset actions (FIXED)
**Status:** ✅ Completed (commit `e502ba5`)

### Problem
- Lock screen never displayed the current track
- Headset play/pause/next buttons controlled a different app because we never registered remote commands
- Pausing from the headset usually resumed playback in another media app instead of Audiobook Player

### Solution
- Added `MPRemoteCommandCenter` handlers for play/pause/toggle/next/previous in `AudioPlayerViewModel`
- Implemented `MPNowPlayingInfoCenter` integration to display track metadata on lock screen (title, album, author, progress, playback rate)
- Added remote command handlers that properly control app playback instead of other media apps
- Updated playback state synchronization for lock screen display on play/pause, seek, track changes, playlist completion, and stop/reset flows
- Added iOS-specific conditional compilation for MediaPlayer framework

### Follow-up / Testing
- ✅ On-device verification confirmed lock-screen metadata and earphone transport controls operate correctly
- ✅ **COMPLETED**: Added lock screen artwork support based on collection cover types
  - **Solid colors**: Creates artwork from collection's solid color covers
  - **Local images**: Loads and displays local image files from document directory
  - **Remote images**: Asynchronously downloads and displays remote artwork URLs
- ✅ Implementation includes UIColor hex extension and UIImage solid color generation
- ✅ Async remote image loading with proper error handling

### Files
- `AudiobookPlayer/AudioPlayerViewModel.swift` - Added artwork handling in `updateNowPlayingInfo()` method

---

## ✅ Bug 4 – Next track shows as playing but audio stalls (FIXED)
**Status:** ✅ Completed (pending commit)

### Problem
- When a track finished, UI jumped to the next track but playback stayed silent
- `AVPlayer` buffered indefinitely because it waited to minimize stalling before starting the new item
- Users had to tap play/pause manually to get audio working again

### Solution
- Disabled `automaticallyWaitsToMinimizeStalling` on newly created `AVPlayer` instances so auto-advance starts immediately
- Replaced all `player.play()` calls with `playImmediately(atRate:)` via a new `startPlaybackImmediately()` helper
- Ensured toggle & remote commands use the same immediate-start helper to keep playback state consistent across UI and lock screen
- Updated remote play handler to rely on the shared helper and refresh now playing metadata

### Follow-up / Testing
- Verify consecutive tracks stream smoothly from Baidu Netdisk over slower connections
- Confirm Bluetooth and lock-screen controls still respond correctly after an auto-advance

### Files
- `AudiobookPlayer/AudioPlayerViewModel.swift`
