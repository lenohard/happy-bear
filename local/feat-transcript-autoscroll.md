# Feature: Transcript Viewer Auto Focus & Scroll

**Status**: 🚧 Active
**Date**: 2025-11-14
**Owner**: Codex agent (GPT-5)

## Request
- When opening the transcript viewer from the Now Playing card, the list should jump to the segment that matches the current playback timestamp instead of starting at the top.
- While audio continues to play, keep the transcript view in sync by auto-scrolling/highlighting the active segment.

## Requirements
1. Detect whether the viewer is showing the same track that is currently playing.
2. On load, highlight + scroll to the segment that matches the player's current time (or the closest segment if between gaps).
3. While playback position changes, keep the highlight and scroll position synced without jitter.
4. Avoid disrupting manual search mode or error states.
5. Ensure the behavior works regardless of where the sheet is presented (Playing tab, collection detail, AI tab, etc.).

## Plan
1. Audit `TranscriptViewerSheet` + `TranscriptViewModel` to understand available playback context hooks and segment helpers.
2. Introduce a scroll targeting mechanism (likely via `ScrollViewReader`) and state to track the current highlighted segment.
3. Wire the viewer to the audio player's `currentTime` and `currentTrack` updates so it auto-selects segments when appropriate.
4. Implement initial focus + continuous auto-scroll, ensuring we throttle to segment changes only and gracefully handle empty/search states.
5. QA in preview (as much as possible) and document any limitations/next steps here.

## Notes / QA
- 2025-11-14: Added ScrollViewReader targeting + auto-follow logic. The sheet now jumps to the active segment on load (when viewing the current track) and keeps tracking segment changes while playback time advances. Search mode intentionally disables auto-follow to avoid fighting manual filtering.
