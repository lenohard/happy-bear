# Bug: Playing card transcript status + summary stats stale

- **Reported by**: user (2025-11-20)
- **Environment**: iOS device build.
- **Summary**: When tapping *Start Transcript* directly from the playing card for a track that already has a finished transcript, the playing card’s status chip never updates to *Completed* and still shows the in-progress label. Inside the transcript summary card the segment and character counts both show `0`, even though the transcript exists.

## Reproduction
1. Start transcription from the playing card while listening to a track.
2. Let the job finish (or retry after it previously succeeded).
3. Observe the status chip stays in the original state and transcript stats read 0 segments / 0 characters.

## Hypotheses
- Playing card status relies on cached `TranscriptionJob` state and isn’t re-fetched once a job transitions to completed.
- Summary stats may rely on `TranscriptMetadata` fields that aren’t recalculated after retrying.

## Plan / Next Steps
- Audit the playing card view model to ensure it listens to transcript/job updates (likely via `TranscriptionStore`, GRDB observation, or notifications).
- Inspect how summary stats are derived (maybe `TranscriptStats` record) and confirm they refresh when the transcript row updates.
- Add targeted logging if needed once code paths are understood.

## Work Log
### 2025-11-20
- Hooked `PlayingView` into the `.transcriptDidFinalize` notification so the status chip refreshes immediately without switching tabs.
- Added a `TrackSummaryViewModel.handleTranscriptFinalized` helper and now invoke it from the playing card notification handler so transcript segment/character counts reload as soon as GRDB finalizes the transcript row.
