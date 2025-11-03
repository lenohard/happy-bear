# Bugs
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

2. Currentlly,  I can't see the playing status in lock sreen and can't use earphone to stop/pauas/next track control to contronl. and when I pause the using earphone it start the audin another app and that app's audio cauase the stop of this app instead stop the audio in this app. 

3. I want to invesgite the search function in baidu netdisk does it have the search in the current folder (rescurly) function.

4. Can't  continuing play next track when a track is done. it just show the next track and the status is palying but it didn't play actually. and I have to click taht track manualy or pause and start again so it can work.

---

## Bug 2 – Lock screen controls & Bluetooth headset actions

### Problem
- Lock screen never displayed the current track.
- Headset play/pause/next buttons controlled a different app because we never registered remote commands.
- Pausing from the headset usually resumed playback in another media app instead of Audiobook Player.

### Fix (2025-11-03)
- Configure `MPRemoteCommandCenter` handlers for play/pause/toggle/next/previous in `AudioPlayerViewModel`.
- Publish now playing metadata through `MPNowPlayingInfoCenter` (title, album, author, progress, playback rate).
- Keep lock-screen state in sync on play/pause, seek, track changes, playlist completion, and stop/reset flows.

### Follow-up / Testing
- Need on-device run to verify headset controls and lock-screen UI (simulator does not expose these hardware integrations).
- Double-check artwork update once collection covers become available.

### Files
- `AudiobookPlayer/AudioPlayerViewModel.swift`
