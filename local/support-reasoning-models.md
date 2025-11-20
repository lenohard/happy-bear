# Support Reasoning Models

## Summary
- User asked to review the current AI usage flow and surface reasoning content that models can now emit so the AI tester/track summary jobs can capture and display those chain-of-thought signals.
- This doc tracks the investigation, decisions, and next steps for wiring reasoning request/response metadata throughout the app and updating the AI Gateway docs.

## Tasks
1. Audit the existing AI stack (`AIGatewayClient`, Job executor, metadata storage, UI) to see how completions/usage are recorded.
2. Add a reasoning toggle for the AI tester, ensure the `reasoning` request payload is optional yet plumbed through to `sendChat`, and capture any returned `message.reasoning` + `reasoning_details` in the job metadata so the detail view can render it.
3. Surface reasoning token counts alongside the usage summary (jobs list + job detail) and update localization strings accordingly.
4. Update `local/ai-gateway-openai-compatible.md` with the new reasoning section and mention the parsing/usage expectations so the AI tab documentation stays aligned.

## Progress
- Created this doc and registered the feature request in `PROD.md`.
- Reasoning section now drafted in `local/ai-gateway-openai-compatible.md` (touched separately).
- Implemented the following:
  1. `AIGatewayReasoning.swift` (new shared models) plus updated `AIGatewayClient`/`AIGatewayModels` to send reasoning configs and deserialize reasoning details / completion token metadata.
  2. `AIGenerationJob` + `AIGenerationJobExecutor` now persist reasoning snapshots, reasoning token counts, and metadata updates for both chat-tester and track-summary jobs; helper `reasoningSnapshot` extracts `message.reasoning` + `reasoning_details`.
  3. AI tab exposes an “Include reasoning” toggle, passes the config when dispatching chat tester jobs, and surfaces reasoning metrics in both the job card and detail view (new usage strings + reasoning section). Localizations were added for all new labels.
- Next: capture any follow-up telemetry or QA notes from the next tester run.
## Current behavior
- Chat tester jobs are the only ones that pass `reasoning` today (track summary/repair use the default).
- Reasoning text/`reasoning_details` are stored on each job’s metadata and exposed in the job detail screen; job cards and lists only surface the optional “Reasoning tokens” line, so the full chain-of-thought is visible only when you open a job’s detail view.
