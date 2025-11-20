# Task: AI Transcript Repair Implementation
- Start: 2025-11-17
- Owner: Codex
- Source: local/ai-transcript-repair.md

## Goal
Deliver the first shippable slice of AI transcript repair: schema support, core model prompt/parse helpers, and orchestration hooks that can update transcript segments while preserving timing.

## Scope (phase 1)
- Add metadata columns (`last_repair_model`, `last_repair_at`, `confidence` aggregation fix) to `transcript_segments` with safe migration.
- Introduce repair request/response models + parser and prompt template using existing AI Gateway client.
- Add `AITranscriptRepairManager` scaffolding that can:
  - fetch segments for a transcript,
  - send a repair batch via AI Gateway,
  - validate indices, and
  - apply edits in a single DB transaction updating metadata.
- Minimal UI hook: temporary entry point callable from debug/test code (no full UI yet).

## Out of scope (later phases)
- Multi-select UI, diff previews, revert history table.
- Background batching and rate limit policies.
- Settings/consent surfaces.

## TODO
- [x] Design migration strategy that works with current schema versioning (no migrator in place).
- [x] Extend models + db manager for new columns.
- [x] Implement repair prompt builder + response parser.
- [x] Add manager orchestration and tests/stubs.
- [x] Update docs (AGENTS.md/ai-transcript-repair.md) with decisions.

## Notes
- Respect existing constraint: do not add new tables for phase 1.
- Keep token budget per request <= ~1500 tokens; chunking to be added later if needed.
- Use stored AI Gateway key + selected model from `AIGatewayViewModel`.
