# Feat: Transcript Viewer Track Summary

## Request
- Source: Follow-on from indicator task recorded in `local/PROD.md` on 2025-11-20.
- Goal: Surface the track summary card inside the transcript viewer whenever the viewer is opened from a collection detail row so listeners can quickly read/replay without leaving the context.

## Objectives
1. Render the existing `TrackSummaryCard` inside `TranscriptViewerSheet` when triggered from `CollectionDetailView`.
2. Hook up a `TrackSummaryViewModel` instance so the summary data loads & stays in sync with transcript/AI job updates while the sheet is visible.
3. Funnel the summary card's seek action back into the transcript viewer playback flow so jumping to a section behaves like tapping a transcript row.
4. Keep other contexts (playing tab / AI tab) unchanged by gating the new UI behind a flag passed from the caller.

## Plan
1. Extend `TranscriptViewerSheet` to accept a `showTrackSummary` flag and own a `TrackSummaryViewModel`/seek helper.
2. Add job/notification listeners so the card refreshes when AI jobs or transcripts change and ensure the summary data loads when the sheet appears.
3. Update `CollectionDetailView` to pass `showTrackSummary: true` when presenting the sheet; keep other callers defaulting to `false`.

## Progress
- 2025-11-20: Added task doc and linked `local/PROD.md` entry.
