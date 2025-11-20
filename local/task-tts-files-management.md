# Soniox File Management UI

## Summary
- expose the Soniox `/v1/files` results directly from the TTS tab so users can see all uploaded audio objects.
- allow manual deletion of stranded uploads in a dedicated files page.
- this supplements the existing transcription jobs section (which already deletes files after the job completes) with a manual cleanup path.

## Requirements
1. Add a Soniox helper to list uploaded files (name, size, created timestamp).
2. Surface a new "Files" row under the TTS tab that navigates to a files list screen.
3. On that screen, allow refreshing the list, show metadata for each file, and enable swipe-to-delete.
4. Keep the UI localized (new strings for the files section, empty state, delete action, etc.).

## Todo
- [ ] Extend `SonioxAPI` with a file-list endpoint + model.
- [ ] Build the files list view (refresh + delete) and hook it up via the TTS tab.
- [ ] Add the new localization entries and update the Soniox docs to mention the UI.
- [ ] Smoke test (navigate to the files page, refresh, and try deleting a file).

## Questions
- Should the files page show the same content even when no key is saved? (Assume the row only appears once a key is configured.)

## Progress
- Task doc created (this file).

