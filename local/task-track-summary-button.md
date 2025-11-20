# Task: Track Summary Header Button Consolidation
- **Date**: 2025-11-20
- **Owner**: Codex (GPT-5)
- **Related Feature**: Track summary card on Playing tab

## Request
The user wants the "Generate" and "Regenerate" actions for track summaries to share a single button placed at the end of the "Track Summary" title line. Tapping this button should kick off summary generation regardless of whether we are creating the first summary or refreshing an existing one.

## Notes
- Existing UI shows a "Generate" CTA only in the idle card body and a "Regenerate" button both in the header and failure state. This causes duplicated CTAs and forces users to scroll if the summary is long.
- The new button should appear whenever generation is possible (transcript + AI key available) and automatically adjust its label/disabled state based on the summary/job status.
- Failure messaging should rely on the shared button instead of bespoke retry/regenerate buttons embedded in the content area.

## TODO
- [x] Update `TrackSummaryCard` header to always host the action button (swap label between Generate/Regenerate, show spinner/disabled state when busy).
- [x] Remove the redundant buttons from idle and failure states while keeping guidance text + stats.
- [x] Verify Active Job/progress UI still works when the only CTA lives in the header (re-reviewed state machine + ran `xcodebuild` to ensure compiler coverage).
- [x] Update documentation (this file + `local/PROD.md`) with the new workflow once implemented.

## Progress
- 2025-11-20 11:05 – Created task doc and logged high-level requirements.
- 2025-11-20 11:45 – Updated `TrackSummaryCard` so a single header button (with spinner state) drives both Generate and Regenerate flows; removed the extra buttons from idle/failure views.
- 2025-11-20 12:20 – Re-checked job states + build output via `xcodebuild -scheme AudiobookPlayer` to ensure no regressions were introduced.

## Files
- `AudiobookPlayer/TrackSummaryCard.swift`
- `local/PROD.md`
