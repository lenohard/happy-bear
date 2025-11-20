# Task: TTS Tab Job Controls & History (2025-11-17)

## Request
- Hide completed and failed transcription jobs by default in the TTS tab; keep only active/prep jobs visible inline.
- Provide a way to view the full job history (including completed/failed) when the user taps into a detail view.
- Add per-job actions: pause, continue/resume, retry, and delete.

## Context
- Current UI lists all jobs grouped by status with no inline actions.
- TranscriptionManager already tracks job status/progress but lacks pause/delete UX hooks.

## Plan / TODO
1. Update TTSTabView job section to show only active jobs with a navigation link/button to "Job History" sheet/list.
2. Build a reusable view for history list (maybe NavigationLink to new sheet) listing completed/failed jobs with timestamps + actions.
3. Add swipe/context actions in both lists exposing pause/resume, retry, delete according to job state.
4. Extend TranscriptionManager with helpers for pause/resume/delete so UI can call them.
5. Wire new actions into the job rows and ensure state refresh works.

## Notes
- Ensure localization keys exist for new labels/buttons.
- Do not commit files under `local/` (doc only).
