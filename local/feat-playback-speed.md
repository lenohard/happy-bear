# Task: Playback Speed Controls

## Summary
Expose variable playback speeds in the Now Playing UI so listeners can slow down or accelerate narration without leaving the app. The request covers both preset speeds (0.5×, 0.8×, 1×, 1.5×, 2×, 3×) and a free-form slider for fine adjustments.

## Requirements
- Persist a global playback speed preference so the player remembers the last selection across launches.
- Apply the chosen rate to AVPlayer immediately (active playback and lock-screen metadata).
- Provide quick-access preset chips plus a slider that covers at least 0.5×–3.0×.
- Work for both library and ephemeral/temporary playback contexts.
- Localize any new strings.

## Plan
1. Extend `AudioPlayerViewModel` with a published `playbackRate`, UserDefaults persistence, rate clamping helpers, and plumbing to update `AVPlayer` + Now Playing info.
2. Add UI controls to `PlayingView`: preset buttons and a slider bound to the view model, plus helper styling for the active selection and numeric readout.
3. Update localization assets + docs (this file + `local/new_xcstrings.md`) so translators know about the new strings; verify layout on compact widths.

## Progress
- [2025-11-16] Document created, plan drafted.
- [2025-11-16] Implemented persisted playback rate in `AudioPlayerViewModel`, wired remote-command support, added Playing tab slider + presets, updated `Localizable.xcstrings`, and ran `xcodebuild` against the iPhone 17 Pro simulator target for regression coverage.
