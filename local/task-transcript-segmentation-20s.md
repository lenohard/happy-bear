# Task: Transcript Segmentation Time Cap

## Request
- **Date**: 2025-11-14
- **Summary**: Adjust the transcription token grouping logic so segments are not only split by speaker changes and sentence-ending punctuation, but also capped at a maximum duration of 20 seconds.

## Notes
- Current implementation: `TranscriptionManager.groupTokensIntoSegments` groups by speaker transitions and punctuation markers.
- New constraint: enforce a hard 20-second (20_000 ms) ceiling per segment regardless of punctuation.
- Need to keep combination logic unchanged for punctuation spacing rules.

## Plan / TODO
- [ ] Add a max-duration constant near the segmenting helper.
- [ ] After appending each token, check duration; if `endMs - startMs >= 20_000`, flush the segment.
- [ ] Verify no empty trailing segments remain and ensure final token flush still runs.
- [ ] Document the change in `local/PROD.md`.
