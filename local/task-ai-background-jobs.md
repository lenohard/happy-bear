# Task: AI Background Generation Jobs

## Request
- Date: 2025-11-19
- Author: user via chat
- Summary: Existing AI flows (chat tester, transcript repair, upcoming summaries) abort when users leave the screen. Need persistent background job manager so AI generations continue off-screen, surface status globally, and reuse for future features.

## Goals
1. Persist AI job metadata (type, prompts, status, streaming buffer, errors) in GRDB so navigation/app suspends don’t wipe work.
2. Run jobs serially/throttled via a dedicated manager/actor that survives across scenes and app launches.
3. Refactor current AI tab tester + transcript repair to enqueue jobs instead of running inline tasks.
4. Provide a shared UI (overlay/list) showing AI job progress + controls (pause, retry, delete) similar to transcription jobs.
5. Lay groundwork for upcoming track-summary auto-generation to plug into the same pipeline.

## Constraints & Notes
- Reuse existing `AIGatewayClient` for API calls; keep provider-agnostic.
- Jobs should capture enough context (trackId, transcript segments, prompts) to resume/retry.
- Need streaming support: store incremental output as job updates so UI can render partial text.
- Align statuses with transcription jobs for consistency (queued, running, completed, failed, canceled).
- Consider disk limits when storing long prompts/responses; maybe compress or chunk.

## Plan
1. Schema / Models: define `AIGenerationJob` table + Codable model (type enum, payload blob, status, timestamps, error, retry metadata, stream buffer). Add migration + DB helpers.
2. Manager: introduce `AIGenerationJobManager` (GRDB CRUD) and `AIGenerationQueue` actor that polls pending jobs, executes via `AIGatewayClient`, streams updates, and handles retries/backoff.
3. Integrations: update `AIGatewayViewModel` tester + `TranscriptViewModel` repair path to enqueue jobs and subscribe to queue updates instead of running tasks inline.
4. UI: add AI job center (reuse AI tab or overlay) plus status badges/toasts when jobs finish/fail. Wire job detail view to stream incremental output/logs.
5. Docs/tests: update this task doc + `local/PROD.md`, add unit tests for parser/queue where feasible.

## Progress Log
- 2025-11-19: Task opened, requirements + initial plan recorded.
- 2025-11-19: Added `ai_generation_jobs` table + Codable models, background executor (`AIGenerationJobExecutor`), and observable manager shared via `AIGenerationManager`. AI tab tester + transcript repair now enqueue jobs instead of running inline, and a new AI Jobs section surfaces live/background job status with deletion controls.
- 2025-11-19: Build surfaced errors related to the new track-summary schema (`TrackSummaryStore`) and an SQLite insert mismatch for `ai_generation_jobs`; need to finish wiring TrackSummaryStore helpers and align the insert statement column count before continuing.
- 2025-11-19 19:30: Fixed the AI job insert mismatch, wired `TrackSummaryStore`, and added relaunch recovery so stuck `running/streaming` jobs fail fast with a localized interruption message. Executor now auto-resumes queued jobs on launch. Remaining work: add pause/resume/retry UI hooks plus Track Summary generation support before closing this task.
- 2025-11-19 20:05: Added cancel support for queued AI jobs plus a collapsed-by-default job list with localized affordances. Cancel is currently limited to queued work; pause/resume/retry still out of scope per latest request. Track summary job execution and richer job center overlays remain TODO.
- 2025-11-19 20:35: Fixed the `TrackSummaryGenerator` parser so section timestamps survive (the snake_case decoder flag was swallowing `start_ms`), and taught `TrackSummaryViewModel` to auto-backfill any completed summary that has zero sections by re-parsing the last AI job payload. Existing summaries now refresh with per-topic sections as soon as the user re-opens the track.
- 2025-11-19 21:05: Playing card now exposes a “start transcription” affordance when a transcript is missing (reusing the viewer button slot), and AI jobs rows open a full-screen detail viewer that shows the complete streamed output/prompts/usage so testers can read everything without truncation.
- 2025-11-19 21:20: Track summary section taps now auto-play from the selected timestamp (no need to hit play after seeking).
- 2025-11-19 21:35: Fixed the missing target membership for `AIGenerationJobDetailView` so the AI job rows can actually present the full-screen detail UI on device builds.
- 2025-11-19 21:50: Smoothed the transcription sheet’s download progress by clamping updates to monotonic growth (prevented the early-stage flicker when the placeholder job fed raw fractions back into the UI).
- 2025-11-19 22:15: Found that `TrackSummaryGenerator.transcriptExcerpt` only fed the first ~10k chars/320 segments to the LLM, so summaries stopped around 10–12 minutes regardless of track length. Adjusted the sampling logic to stride across the entire transcript so long recordings now produce sections through the end.
- 2025-11-19 22:30: Documented the first-pass sampling approach (stride up to 320 segments, ~32k char cap, always include the final segment) so we had a baseline while testing. This setup has since been superseded by the unlimited prompt feed noted below.
- 2025-11-19 22:50: Added transcript stats (segment + character counts) to the Track Summary card whenever a transcript exists but no summary has been generated yet, so testers know what the AI will ingest. Temporarily removed all excerpt sampling and caps—`TrackSummaryGenerator` now streams every transcript segment verbatim so you can evaluate full-length prompts before we design the next sampler.
- 2025-11-19 23:05: Disabled the `transcriptDidFinalize` auto-enqueue hook in `AIGenerationManager` so summaries are only generated when the user taps the button; no more surprise jobs when a transcript finishes syncing.
