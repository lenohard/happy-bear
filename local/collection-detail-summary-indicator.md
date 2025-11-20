# Feat: Collection Detail Summary Indicator

## Request
- Source: Handed off via `local/PROD.md` tracker and user request on 2025-11-20.
- Goal: Surface a visual indicator in the collection detail track list whenever a track already has an AI-generated summary so listeners can spot pre-summarized tracks at a glance.

## Objectives
1. Determine how to detect whether a track has a ready summary (status complete + non-empty body) without re-fetching everything repeatedly.
2. Render a small summary icon in `CollectionDetailView` alongside the metadata row for each track that qualifies.
3. Keep the indicator in sync with summary generation by reacting to job status updates and collection changes.
4. Add the new localization string(s) used for the accessibility label of the indicator.

## Plan
1. Track summary presence via the GRDB store; add a helper to fetch all track IDs that already have ready summaries (if one does not exist yet).
2. Store the ready track IDs in `CollectionDetailView` state and refresh them when the collection, AI jobs, or transcripts change.
3. Pass the flag into `TrackDetailRow` and show an icon next to the existing metadata icons.
4. Publish a new localized string for the indicator.

## Notes
- This is mostly a UI touchup, so no new view controllers are needed.
- Keep indicators updated when the user switches collections or after a summary job completes.
- Remember to keep `local/` docs out of commits.

## Progress
- 2025-11-20: Created task doc and outlined plan.
- 2025-11-20: Implemented the summary indicator refresh state + Task, hooked the icon into `CollectionDetailView`, rustled the helper to fetch ready summaries, and added the localized label so rows with cached summaries render the badge (`AudiobookPlayer/CollectionDetailView.swift`, `AudiobookPlayer/TrackSummaryStore.swift`, `AudiobookPlayer/Localizable.xcstrings`).
- 2025-11-20: Switched the helper query to use `StatementArguments` so the `fetchTrackIdsWithCompletedSummaries` call compiles cleanly (`AudiobookPlayer/TrackSummaryStore.swift`).
