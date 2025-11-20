# Bug: AI tester job stuck running (2025-11-19)

## Report
- User force-closed the app while a chat tester job was streaming.
- After relaunching on November 19, 2025, the tester UI still shows the job as “Running” and disables the Run button, so the user cannot run a new test.

## Observations / Suspicions
- `ai_generation_jobs` rows remain in `running` or `streaming` status if the executor dies mid-stream.
- `AIGenerationJobExecutor` only dequeues jobs marked `queued`, so `running` rows never resume.
- `AITabView.chatJobInProgress` simply checks for any active chat job, so stale rows keep the button disabled indefinitely.

## Proposed Fix
1. At app start, detect any non-terminal AI jobs that were left in `running`/`streaming` status and mark them as failed with a friendly error so they fall out of `activeJobs` and show up in history.
2. Kick the executor if there are lingering `queued` jobs after relaunch so they resume automatically.
3. Add localization for the interruption error string.

## Tasks
- [x] Add DB helpers (`failInterruptedAIGenerationJobs`, `hasQueuedAIGenerationJobs`).
- [x] Call the helpers when `AIGenerationManager` boots before the refresh loop.
- [x] Add localized copy for the interruption error message.
- [ ] Smoke test by simulating a stuck job (set status to `running`) and confirm it is downgraded to `failed` after relaunch.

## Notes
- Keep existing job history so the user can re-run manually.
- Do not auto-requeue chat tester jobs—the user should explicitly re-run to avoid duplicate usage.
