# Task: Baidu Browser Direct Play Sheet Fix

**Created:** 2025-11-08  
**Status:** In progress

## Request Summary
- The Baidu Netdisk file action sheet layout looks unfinished compared to the provided mock (2025-11-08 screenshot). Typography, spacing, and button hierarchy need to match the reference so the file name/path are readable and the primary CTA is emphasized.
- Selecting an audio file inside the Baidu browser currently starts playback immediately, even before the sheet appears. The user wants playback to start **only** after tapping the “立即播放 / Play Now” button in the sheet.

## Requirements
1. Preserve the file summary sheet but restyle it (header, typography, spacing, hints) to align with the supplied screenshot, keeping the primary play button prominent and the “Save parent folder” action secondary.
2. When a Baidu audio file row is tapped, simply present the sheet; do **not** trigger playback until the user confirms via the Play button.
3. Continue disabling the Play button for unsupported formats and keep the “Save to Library” flow available from the same sheet.

## Plan
- Update `SourcesView` selection handling so `handleNetdiskFileSelection` only stores the entry & shows the sheet.
- Rebuild the sheet UI into a dedicated SwiftUI view that mirrors the reference layout (large header, rounded info card, inline description, anchored CTAs).
- Wire the Play button to dismiss the sheet and invoke `audioPlayer.playDirect`, reused actions for saving the parent folder, and ensure localization keys are reused.

## Progress
- [x] Documented the request & acceptance criteria (this file).
- [x] Update selection flow + UI layout (`AudiobookPlayer/SourcesView.swift` + new `NetdiskEntryDetailSheet`).
- [x] Test via `xcodebuild -scheme AudiobookPlayer -destination 'platform=iOS Simulator,name=iPhone 17' build` (warnings only for duplicate GRDB files, consistent with previous runs).
- [x] Summarize changes + update PROD entry (PROD link added 2025-11-08; final summary shared in session notes).
