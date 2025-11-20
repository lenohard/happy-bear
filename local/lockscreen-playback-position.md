# Feature: Enable Lock-Screen Scrubbing

## Created
- 2025-11-16
- Request: "why I can't slide the playback controls in the player card of lock screen of this app?" → convert into actionable feature: allow lock-screen change playback position.

## Problem
- iOS lock screen scrubber disabled because `MPRemoteCommandCenter.changePlaybackPositionCommand` not configured.
- AVPlayer already reports current time/duration, so hooking the command should unlock slider.

## Goal / Acceptance Criteria
1. Lock screen scrubber becomes draggable on iOS devices.
2. Seeking from Control Center/lock screen updates in-app playback state, `AudioPlayerViewModel.currentTime`, and `MPNowPlayingInfoCenter` metadata.
3. Remote command target cleaned up when teardown occurs.
4. Add lightweight QA checklist/manual test notes.

## Plan
- [x] Inspect `AudioPlayerViewModel` remote command plumbing and confirm missing change-position command.
- [x] Implement handler: enable command, register target, seek player, refresh state, handle failure cases.
- [x] Ensure command removed in `clearRemoteCommandTargets`.
- [ ] Update docs (PROD + this file) + describe testing expectations.
- [ ] Run targeted tests (simulator or unit) if applicable; otherwise document manual validation path.

## Notes
- `AVPlayer` seeking requires main thread; use `seek(to:toleranceBefore:after:)`.
- After seeking, call `updateNowPlayingElapsedTime()` so metadata matches.
- Consider ignoring commands when no track is active or player nil.
- Keep instructions in AGENTS/PROD consistent.

## Test / QA Checklist
- [ ] On a physical device, start playback, lock the screen; drag the scrubber — expect immediate seek and resumed playback at new position.
- [ ] Verify elapsed time + remaining time labels update alongside the seek on lock screen.
- [ ] Open the app after seeking from lock screen and confirm in-app slider reflects the new position.
- [ ] Try edge cases: scrub to 0s, scrub to near end; ensure no crash and completion fires normally.
- [ ] Pause/play via lock-screen buttons still works after scrubbing.

## Notes from Impl (2025-11-16)
- Enabled `changePlaybackPositionCommand` and added handler that clamps to known duration and reuses existing `seek(to:)` path, so observers + `updateNowPlayingElapsedTime()` are triggered.
- Target is stored in `remoteCommandTargets` so teardown removes it consistently.
