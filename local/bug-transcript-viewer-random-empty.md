# Bug: Transcript Viewer empty until random success

**Status**: Investigating (2025-11-09)
**Reporter**: user (Nov 9 session)
**Related Docs**: `local/stt-integration.md`

## Description
- Several tracks already have completed Soniox transcripts.
- After a cold app launch, opening "View Transcript" for any track usually shows the sheet but the body is blank / "no transcript" message.
- Trying other tracks eventually surfaces one whose transcript loads normally; once any transcript loads, all other tracks begin showing their transcripts without issue for the remainder of the session.

## Reproduction Notes
1. Launch the app fresh.
2. Navigate to any collection with completed transcripts and open a transcript via the context menu.
3. Observe empty sheet.
4. Repeat with other tracks; eventually one succeeds.
5. After a success, reopen previously failing tracks — they now show text immediately.

## Initial Observations / Hypotheses
- Behavior suggests the GRDB database (or transcription tables) is not fully initialized when the first TranscriptViewerSheet tries to query.
- Once the database is initialized (triggered by some other component), subsequent loads succeed.
- Need to confirm whether `GRDBDatabaseManager.initializeDatabase()` is being awaited everywhere transcripts are read, or add an explicit guard in `TranscriptViewModel`/`TranscriptionManager` to ensure initialization before any query.

## Next Steps
- [x] Inspect `TranscriptViewModel.loadTranscript()` call flow to see if it should call into a database-initialization helper.
- [x] Add `ensureDatabaseReady()` method inside `GRDBDatabaseManager` and reuse anywhere transcription code hits SQLite without going through LibraryStore.
- [ ] Verify transcripts load on the first attempt after app launch.
- [x] Note findings + regression instructions back in `local/stt-integration.md` once fixed.

## Additional Fix Attempt (2025-11-10 Afternoon)

- Switched transcript sheet presentation to `.sheet(item: $trackForViewing)` so SwiftUI always has a non-nil `AudiobookTrack` when rendering the sheet.
- Removed the separate `showTranscriptViewer` boolean flag to eliminate timing/race conditions that could present an empty sheet before the track was set.
- Mirrored the same `.sheet(item:)` pattern inside `AITabView` so tapping a completed transcription job opens the viewer with the selected job baked into the state before presentation.
- Temporary TranscriptLogger instrumentation (view model + sheets) was removed once the bug was resolved to keep release builds quiet.
