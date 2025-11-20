# Bug Fix: Transcript Viewer Segment Selection & Search Layout

**Status**: 🚧 Active
**Date**: 2025-11-13
**Owner**: Codex agent (GPT-5)

## Problems

### Bug 1: Segment Tap Jumps Wrong Track
- Transcript viewer segments should scrub only the transcript's associated track.
- Currently, tapping any segment forces the global audio player to seek, even when another track is playing.
- Expected: either refuse to control playback if unrelated, or switch context explicitly after user confirmation.

### Bug 2: Search UI Breaks Line Wrapping
- When using the transcript search box, rows collapse into single-line layout.
- Long lines become truncated/ellipsized permanently after searching, even when search is cleared.
- Need to preserve full text wrapping, ensure search results stay readable, and keep the default (non-search) layout untouched.

## Hypotheses / Leads
- Segment tap probably calls `AudioPlayerViewModel.seek(to:)` without verifying the active track ID.
- Transcript viewer may rely on `Text` with `.lineLimit(1)` toggled during filtering; search state might not reset `lineLimit(nil)`.
- Search results list might force `horizontalSizeClass == .compact` single-line style.

- [x] Compact transcript rows and keep localized metadata while searching.
- [x] Add a transcript indicator button to the Playing tab (left of Favorite) that opens the viewer when ready.
- [ ] Add targeted unit/UI tests if feasible (snapshot or view model tests) or document manual QA.
- [x] Update this doc + PROD entry when done.

## Notes
- Related prior bug doc: `local/bug-transcript-viewer-random-empty.md` (check for shared view structs).
- Transcript data likely lives in `TranscriptViewerStore` or `TranscriptionModels.swift`.

## Progress - 2025-11-13

### Segment control respects track context
- Added `LibraryStore` + `BaiduAuthViewModel` environment objects to `TranscriptViewerSheet` so we can resolve the owning collection/track for a transcript.
- `jumpToSegment` now looks up that context, auto-loads the correct collection/track via `AudioPlayerViewModel.play`, and only then seeks to the requested timestamp.
- If the track no longer exists we surface a localized alert instead of seeking the wrong audio (previous behavior).

### Search layout + UX polish
- Replaced transcript/search stacks with `LazyVStack` to keep performance snappy.
- Removed the `lineLimit` clamps and force-wrapping search rows so long lines render fully in both normal and search modes.
- Added `SearchSummaryView` header that reiterates the query and shows a localized match count so users know how many hits were found.
- Search result rows now use localized match chips (`1 个匹配` / `%d 个匹配`), show only the start timestamp, and drop the repetitive English "Found ..." text from the old build.
- Transcript segment rows use denser padding, monospaced timestamps, localized confidence labels, and rounded selection backgrounds so the list is visibly more compact (matches the second screenshot ask).

### Now Playing transcript entry point
- Added a floating transcript button directly on the playing card header (only appears when a transcript exists). Tapping it opens `TranscriptViewerSheet` instantly; otherwise the UI stays clean with no placeholder label, per the request.
- Fixed the underlying status check so we treat both `complete` and `completed` transcript rows as done—previously the DB stored `completed`, so the button never showed up even when data existed.

- `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -sdk iphonesimulator build` (retried after Color/ShapeStyle fix; continues to time out after ~3m while resolving SwiftPM graph, so no compilation verdict yet).
- Manual reasoning through updated `TranscriptViewerSheet.swift` + `PlayingView` to ensure environment objects are available wherever the sheet is presented (CollectionDetail, AI tab, Playing tab chip).
