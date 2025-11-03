# Bugs & Enhancements
2025-11-04 星期二

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
- ✅ iOS 16 compatible (uses `onReceive(Just(_))` instead of iOS 17+ `onChange`)

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
