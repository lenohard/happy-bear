## Quick action localization (2025-11-17)

### What changed
- Home Screen quick action title now uses localized strings (English + Simplified Chinese) instead of a hard-coded English title.

### Files touched
- `AudiobookPlayer/Info.plist`
- `AudiobookPlayer/en.lproj/InfoPlist.strings`
- `AudiobookPlayer/zh-Hans.lproj/InfoPlist.strings`
- `AudiobookPlayer.xcodeproj/project.pbxproj` (added InfoPlist.strings variant group and resource entry)

### Steps (repeatable)
1) In `Info.plist`, set `UIApplicationShortcutItemTitle` to a key, e.g. `continue_last_play_shortcut`.
2) Create localized files:
   - `en.lproj/InfoPlist.strings`: `"continue_last_play_shortcut" = "Continue Last Play";`
   - `zh-Hans.lproj/InfoPlist.strings`: `"continue_last_play_shortcut" = "继续播放";`
3) Add an `InfoPlist.strings` variant group to the project, include both localizations, and ensure it’s in Copy Bundle Resources.
4) Build and long-press the app icon; the title follows system language.

### Notes
- For future config-heavy tasks, prefer handing off instructions first per collaboration note in AGENTS.md (2025-11-17).
