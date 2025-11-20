# Bug Fix: Transcript Viewer Initial Focus

**Status**: 🚧 Active
**Date**: 2025-11-17
**Owner**: Codex agent (GPT-5)

## Problem
- Opening the transcript sheet for the currently playing track should automatically scroll the list to the active (highlighted) segment so the user sees where playback is.
- Actual: the sheet opens at the top (segment 1). It only scrolls into place when playback advances to the next segment, so the initial state is confusing when jumping deep into a book.
- Severity: regression of "Transcript Viewer Auto Focus" feature noted in `local/feat-transcript-autoscroll.md`.

## Reproduction Steps
1. Start playback on any track with an existing transcript.
2. Tap the transcript button on the Playing tab (or Library/AI contexts) to open `TranscriptViewerSheet`.
3. Observe the list opens at the start instead of the currently playing timestamp.
4. Wait for the next transcript segment to become active; only then does the list scroll.

## Expected Behavior
- When the sheet appears it should immediately highlight and scroll to the segment whose `startTime...endTime` overlaps the player's current time.
- If no segment is active (e.g., transcript incomplete), keep current behavior but avoid unnecessary scroll jumps.

## Hypotheses / Leads
- Auto-scroll may be tied solely to a `.onReceive` of the playback ticker, so the initial focus never fires until the next tick after presentation.
- There may already be a helper (e.g., `scrollToSegmentIfNeeded`) that needs to run from `.task`/`.onAppear` once transcripts load.
- Need to guard against double scrolling when the sheet opens mid-transition or when the user has manually scrolled away.

## Plan / Tasks
1. Inspect `TranscriptViewerSheet`, `TranscriptViewerStore`, and related view models to find the existing auto-focus logic introduced in `local/feat-transcript-autoscroll.md`.
2. Add an initial focus action triggered when:
   - the sheet appears and playback info is available, or
   - the transcript content finishes loading and `currentSegmentID` resolves.
   Track whether the initial scroll has already run.
3. Ensure we still respect manual override (if the user scrolls, don't snap back unless `followPlayback` is re-enabled).
4. Smoke-test on iOS simulator (or reasoning through instrumentation) to confirm:
   - Opening from Playing tab jumps to active segment immediately.
   - Opening from Library / search results works even if playback paused.
   - No regressions to ongoing auto-follow behavior while playback progresses.

## QA / Validation Checklist
- [ ] Open transcript mid-track; list focuses on highlighted cell immediately.
- [ ] Resume playback to ensure follow-along still works after initial focus.
- [ ] Open transcript when playback is paused; ensure highlight and focus still accurate.
- [ ] Opening transcripts for non-playing tracks keeps default scroll (top) but does not crash.

## Notes / Links
- Original feature doc: `local/feat-transcript-autoscroll.md`.
- Related bug doc: `local/bug-transcript-viewer-selection-search.md` (ensures we don't regress row layout while adjusting scroll behavior).

## Progress – 2025-11-17

- Updated `TranscriptViewerSheet.setScrollTarget` to blank out the target and reapply it on the next runloop tick via `DispatchQueue.main.async`. This guarantees `ScrollViewReader` receives a fresh state change (even if we request the same segment ID twice) and waits until the list rows are actually in the hierarchy before attempting `scrollTo`.
- Added a short inline comment documenting why we reset the target ID so future tweaks don't regress the behavior.
- Verified the project builds on iPhone 17 Pro simulator: `xcodebuild -scheme AudiobookPlayer -project AudiobookPlayer.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` (warnings about duplicate GRDB/DB files persist from previous sessions but no new errors).
