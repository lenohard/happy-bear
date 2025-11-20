# AI Transcript Repair – Notes

## Context
- Date: 2025-11-?? (session with Codex)
- Topic: Use integrated LLMs to clean up Soniox transcripts inside Audiobook Player.
- Source discussion: user asked how transcripts are stored and whether Viewer segments are assembled on the fly. We confirmed storage and brainstormed AI repair workflow.

## Current Transcription Storage
- GRDB SQLite at `~/Library/Application Support/AudiobookPlayer/library.sqlite` (see `DatabaseConfig.defaultURL`).
- Tables from `TranscriptionDatabaseSchema`:
  - `transcripts`: per-track full text, status, Soniox job metadata.
  - `transcript_segments`: paragraph-level text with start/end ms, speaker, language, confidence.
  - `transcription_jobs`: async job tracking (status/progress/retries).
- `TranscriptionManager` builds segments by grouping Soniox tokens before saving via `GRDBDatabaseManager.saveTranscriptSegments`. Transcript Viewer simply reads persisted segments; nothing is reassembled at runtime.

## AI Repair Idea
Goal: Let user trigger an AI pass that rewrites low-quality transcript segments without losing timestamps.
(allow ai repaired or user manual edit two modes)

Possible flow:
1. user seelct the segments.
2. format segments(one by a line with index)  feed to existing LLM integration (AITab’s providers).
3. Prompt instructs model to:
   - Correct spelling while keeping meaning.
   - Avoid changing timestamps, segment count, or inserting/removing speakers.
   - Return JSON `{index, edited_text}` to simplify parsing.
4. Persist results:
   - Replace origin segments with this edit ones.

## Next Steps
2. Define prompt + response schema for preferred LLM .
3. Implement `AITranscriptRepairManager` (maybe inside `TranscriptionManager` or AITab module) that:
   - Fetches target segments.
   - Sends repair requests.
   - Applies DB updates atomically.
4. Update Transcript Viewer to surface repaired text and toggles.
5. Document consent/usage in Settings and AGENTS.md once implementation starts.

## Functional Requirements (2025-11-14)
- Preserve Soniox output verbatim for auditability while layering AI edits as an optional view.
- Enable three scopes: per-segment repair, "repair all low-confidence segments" bulk action, and full transcript rewrite for edge cases.
- Ensure every change keeps segment boundaries + timestamps identical so waveform sync and jump-to-segment remain accurate.
- Track provenance (model, prompt version, user, timestamp) so future Soniox re-runs or manual edits can roll back safely.
- Offer a diff/preview before committing edits and allow one-click revert to original text.

## Data Model / Storage Plan
- **No new tables.** We now edit `transcript_segments.text` in place once the user accepts an AI repair. Simpler to ship, but we must track metadata elsewhere (see below).
- `transcript_segments` additions:
  - `last_repair_model` (TEXT, nullable) – remember which LLM touched it last.
  - `last_repair_at` (DATETIME) – auditing + “undo if old” heuristics.
  - `confidence` column already exists; we will start persisting an aggregate so low-confidence filtering works reliably.
- History concerns: we lose verbatim Soniox text after edits. Mitigation: export the untouched transcript before applying bulk repairs (optional toggle) or rely on Time Machine/backups. Good enough for phase 1 per user request.

## Repair Workflow Outline
1. **Selection**
   - Transcript Viewer exposes multi-select mode; default filter selects segments where `confidence < 0.85` (see confidence aggregation note below) or by manual searching.
2. **Packaging & Prompting**
   - `AITranscriptRepairManager` batches segments (≤1 500 tokens each request). Payload now contains only `index` and `text` because timestamps/speakers are implied by the client:
     ```
     [
       { "index": 12, "text": "teh wizzard..." },
       { "index": 13, "text": "he sayd..." }
     ]
     ```
3. **Validation**
   - Ensure every returned index exists
4. **Preview**
   - Show diff (original vs AI) in Transcript Viewer; store results in-memory as `preview` revisions.
   - User can accept all, accept per segment, or discard.
5. **Commit**
   - When accepted, insert rows into `transcript_segment_edits`, set `active_revision`, update `repair_state = applied`, and write audit log entry referencing repair job + LLM model.

## Prompt Proposal (v0)
```
SYSTEM:
You repair audiobook transcripts. 
Return JSON: {"repairs":[{"index":NUMBER,"edited_text":"CLEAN TEXT"}]}.
Constraints: only return the lines requiring corrections; no line breaks unless original had them; do not hallucinate proper nouns; keep language consistent with input.

USER:
Segments
[12] teh wizzard finaly arrvied.
[13] he sayd, "welcom bak, hero!"
```
Parsing logic can live beside `AITranscriptRepairManager` so the rest of the app just receives `[SegmentRepair]`.

## UI / UX Touchpoints
- **Transcript Viewer**:
  - Add toolbar button "Repair Transcript" 
  - Multi-select list with confidence chips; selection count summary + "Send to AI" CTA.
  - Preview screen showing side-by-side cards or inline diff; checkboxes to accept per segment.
- **Settings**:
  - Option to auto-select low-confidence segments threshold and threshold

## Implementation Notes
- Manager location: keep orchestration inside `TranscriptionManager` (so it already has DB + Soniox context) but inject `AIGatewayClient` (or generic `LLMClient`) plus `TranscriptRepairPolicy`.
- Concurrency: optional `TaskGroup` for parallel batches; throttle to avoid provider rate limits.
- Migrations: add `last_repair_model`, `last_repair_at`, and ensure `confidence` is populated (see below). Update `TranscriptionDatabaseSchema` + `GRDBDatabaseManager`.
- When applying edits:
  - Wrap in one transaction per batch.
  - Update `transcript_segments.text`, `last_repair_model`, `last_repair_at = Date()`.
  - Consider writing a lightweight audit row into existing `transcription_jobs` or a new log file only if needed later.
- Tests:
  - Unit tests for prompt/response parser (invalid JSON, missing indexes).
  - DB tests ensuring in-place edits persist + metadata updates.
  - UI snapshot tests for repaired badge states if feasible.

### Segment Confidence Aggregation
- Soniox only supplies `confidence` per token (`SonioxToken.confidence`). We’ll compute the segment-level value while grouping tokens:
  - Take the arithmetic mean of confidences for tokens that fell into the segment (`sum / count` ignoring nils). If every token lacks confidence, leave `confidence = nil`.
  - Store that mean in `TranscriptSegment.confidence` so low-confidence filters have deterministic input.
- This calculation fits naturally inside `groupTokensIntoSegments` before we append the segment.

## Open Questions
1. Can we keep all processing on-device for privacy when a local model becomes available, or is remote AI acceptable behind explicit consent?
use remote. don't use local model.
2. Should manual edits share the same revision table so we can expose a basic text editor without duplicating storage?
ok
3. Do we need to cache AI responses to avoid double-billing if the user replays the same selection without changes?
no

## 2025-11-17 Progress
- Added `last_repair_model`/`last_repair_at` columns on `transcript_segments` plus average-confidence calculation during Soniox token grouping so low-confidence filters work predictably.
- Introduced `AITranscriptRepairManager` with prompt builder + JSON parser that calls the existing AI Gateway via chat completions, validates indexes, and persists edits atomically through `GRDBDatabaseManager.applyTranscriptRepairs`.
- `TranscriptViewModel` now exposes `repairSegments(at:trackTitle:model:apiKey:)` for future UI to invoke repairs; any successful run reloads segments and stores the diff results for preview rendering.
- Transcript Viewer bottom toolbar now offers a gated "Repair Segments" toggle when an AI key exists; repair mode exposes checkbox selection, inline status banners, and a progress indicator while dispatching the batch to `AITranscriptRepairManager`.
- Build verified on November 17, 2025 with `xcodebuild -scheme AudiobookPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- Transcript Viewer repair mode now exposes an auto-select slider (default 90%) that selects all segments whose confidence is below the chosen percentage.
- Transcript row layout now pins the text column to the same top alignment as the timestamps to avoid misalignment in Chinese copy.
- Auto-select panel now includes a toggleable select/unselect button plus a 'show selected only' filter for quickly reviewing low-confidence segments.
- AI transcript repair manager logs the outbound prompt and raw AI response via OSLog for debugging.
- Filter toggle moved next to search so it works outside AI repair mode; slider defaults to 95% and repair toolbar uses a back chevron icon when active.
- Repair mode shows indicator chips for segments already touched by AI and offers icon-only toggles for selection filtering and hiding repaired rows.

