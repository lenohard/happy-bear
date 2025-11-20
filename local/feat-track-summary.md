# Feat: Track Transcript Summaries & Sections

## Request
- Source: 2025-11-19 product sync with user
- Goal: Automatically summarize each track using its transcript and split long recordings into readable sections with timestamps and blurbs.

## Objectives
1. Produce a concise, two-to-three sentence overview for the entire track so listeners can preview the content without skimming the whole transcript.
2. Generate a structured outline that divides the track into monotonic time ranges (start timestamp + optional end) with per-section summaries and optional titles.
3. Persist generated summaries/sections so we can reuse them offline and avoid rerunning LLM summarization every time.

## Functional Requirements
1. **Input data**: Use existing transcript segments (text + timestamps). Handle tracks that already have sections manually added by future features (decide whether to merge or replace).
3. **Summary format**: Each section includes `start_at`, `title`, and `summary`. The overall track summary stores `title`, `summary`, `keywords/tags`, and `last_generated_at` metadata.
4. **LLM pipeline**: Reuse the existing AI gateway abstraction (same infra as transcript repair and batch rename) so providers can be swapped. Submit the cleaned transcript text + metadata prompts and parse JSON output safely with validation.
5. **Persistence**: Extend GRDB/SwiftData schema (whichever is active) with tables like `TrackSummary` and `TrackSection`. Associate rows with `trackId` and version the schema for migrations. Cache the generated data in-memory for quick UI rendering.
6. **UI/UX**: add the create button in the playing card and the result is displayed in the playing card so I can jump using the starttime of each seciton and read the section summary. 
7. **Background processing**: Kick off generation automatically after a transcript finishes downloading, but throttle so only one track processes at a time and show status in AI/Jobs center.
8. **Error handling**: On failure, show retry CTA with the last error string. Log events for instrumentation and mark partial results invalid until fully parsed.

## Dependencies & Research
- Review existing transcript storage (`TranscriptSegment`, AI repair flows, GRDB migrations) to reuse parsing helpers.
- Transcript data models live in `TranscriptModels.swift` alongside `Transcript`, `TranscriptSegment`, `TranscriptionJob`; this is where new structs like `TrackSummary`/`TrackSection` should be defined.
- GRDB access flows through `GRDBDatabaseManager.saveTranscript`, `loadTranscript`, `loadTranscriptSegments`, and `applyTranscriptRepairs`; new summary tables and CRUD helpers belong here so the rest of the app can stay ignorant of SQL.
- Transcript UI + VM live in `TranscriptViewerSheet.swift` and `TranscriptViewModel.swift`, both already injected with `AIGatewayViewModel`, making them the natural surface for summary rendering/regeneration controls.
- `TranscriptionManager` triggers Soniox jobs and finalizes transcripts; we can piggyback on its completion path to auto-enqueue summary generation once `finalizeTranscript` succeeds.
- `AITranscriptRepairManager` + `AIGatewayClient` demonstrate the existing JSON-based LLM flow (prompt builder, parser, error handling) we can mirror for summaries/sections.
- The Now Playing primary card (`ContentView.swift` → `PlayingView.primaryCard`) is where the “Generate summary” button and outline display will sit so users can jump via timestamps.

## Proposed Architecture

### Data Model & Persistence
- Add `TrackSummary` + `TrackSummarySection` structs beside the other transcript models so everything related to transcripts stays co-located. Fields:
  - `TrackSummary`: `id`, `trackId`, `transcriptId`, `language`, `summaryTitle`, `summaryBody`, `keywordsJSON`, `sectionCount`, `modelIdentifier`, `generatedAt`, `status` (`idle|generating|failed|complete`), `errorMessage`, `lastJobId` (FK to AI jobs for traceability).
  - `TrackSummarySection`: `id`, `trackSummaryId`, `orderIndex`, `startTimeMs`,  `title`, `summary`, `keywordsJSON` (optional) to future-proof tagging.
- Extend GRDB schema with two tables mirroring the models plus indexes on `track_id` and `track_summary_id`. Each track gets ≤1 active summary row; regenerate overwrites the same row after clearing sections, while we keep `generatedAt`/`modelIdentifier` history in the AI job table.
- Reuse the upcoming `AIGenerationJob` table from `local/task-ai-background-jobs.md` (type enum, payload blob, status, retry metadata). The summary feature publishes jobs with `type = track_summary` and persists payloads referencing the transcript + chunking parameters so retries don’t need to recompute inputs.
- New GRDB helpers:
  - `fetchTrackSummary(trackId:)`, `fetchTrackSummarySections(summaryId:)`
  - `upsertTrackSummary(summary: TrackSummary, sections: [TrackSummarySection])`
  - `markTrackSummaryStatus(trackId:, status:, error:)` for UI/queue coordination.

### Job Pipeline & Flow
1. **Trigger**: when transcription completes (`TranscriptionManager.finalizeTranscript`) or when user taps “Generate summary” on Playing card.
2. **Enqueue**: `TrackSummaryGenerationService` (new helper/actor) prepares a `TrackSummaryJobPayload` (track metadata, transcriptId, flattened segments, chunk parameters) and registers an `AIGenerationJob` row. If a summary exists + status `complete`, tapping “Regenerate” overwrites status to `queued` and clears section rows while retaining last published summary until new results replace it.
3. **Execution**: the shared `AIGenerationQueue` actor (from background-jobs task) dequeues jobs FIFO, streams prompts through `AIGatewayClient`, and writes incremental output into the job row so the job center can show progress. Once the model returns valid JSON, the queue parses it (using a dedicated `TrackSummaryResponseParser`) and calls `GRDBDatabaseManager.upsertTrackSummary` within the actor.
4. **Completion hooks**: after persistence, emit notifications (`NotificationCenter` or Combine subject) so Playing/Transcript views refresh automatically. Failures write `status = failed` + `errorMessage`, leaving the previous summary (if any) untouched until user retries.
5. **Throttling**: rely on the AI job queue’s single-flight behavior so only one generation runs at a time, matching the requirements in `local/task-ai-background-jobs.md`.

### UI Surface
- Playing card gains a `TrackSummaryCard` area with states: `empty` (CTA button), `pending` (spinner + message referencing AI job), `failed` (error + retry), `ready` (overall summary text + vertically stacked section chips showing `start` + `title` + truncated summary). Tapping a chip seeks playback via `AudioPlayerViewModel.seek(to:)` using `startTimeMs / 1000`.
- Transcript viewer adds a Summary tab (toggle) reusing the same data so users can read sections while scrolling full transcript (optional if scope grows).
- AI job center lists “Track Summary” jobs with track artwork/name for visibility, tying into the background-job docs.

### Prompt & Response Design
- **System prompt**: “You are an audiobook editor. Produce a JSON summary with overall synopsis plus ordered sections. Preserve chronology, keep section lengths consistent, and never hallucinate timestamps.” Include explicit schema example so LLM output stays parseable.
- **User prompt template**:
  - Track metadata block (title, narrator/author if available, collection name/description, total duration).
  - Transcript context: either concatenated transcript text or chunked excerpts with `[HH:MM:SS(start_time)]` headers so the model can anchor timestamps.
  - Instructions about section length targets (e.g., “aim for 3–5 minute spans, cap at 1,200 characters of transcript per section”) and style (“2 sentences per section, neutral tone”).
  - Output contract: JSON with top-level `summary` (title, overview, keywords array) and `sections` array where each object includes `order`, `start_time`, `title`, `summary`, `key_points`. Provide a mini schema + sample object.
- **Chunking approach**: summarize via map/reduce when transcripts are huge—first ask for coarse sections (timestamps only) then re-summarize each section; or stream a single prompt if under token limits. Persist chunk metadata in the job payload for retries.
- **Parser**: strict Decodable struct `TrackSummaryResponse` mirroring the contract; log raw responses when decoding fails and mark job as `failed` with parser error so QA can review.

## Open Questions
1. Should we expose user controls for desired section length or only automatic (maybe preset short/medium/long)?
automatic
2. Is the outline meant to be shareable/exportable (e.g., copy to clipboard, export as Markdown)?
no
3. Where else should we surface the summary (collection cards, lock screen metadata)?
now playing card.
4. What limits do we set before auto-generation triggers (e.g., transcripts shorter than 2 minutes might not need sections)?
no limits

## Progress Log
- 2025-11-19: Initial task doc drafted, awaiting design/product feedback.
- 2025-11-19 19:05: Added `TrackSummary` data models, GRDB schema (`track_summaries`, `track_summary_sections`), and persistence helpers (`TrackSummaryStore`). Build fixed by updating AI job table insert statement to include all columns. Next session: finish Track Summary job pipeline + UI surface, and address stuck-running AI jobs after app relaunch.
- 2025-11-19 22:40: Implemented the Track Summary generation pipeline end-to-end (prompt builder/parser, executor streaming, job enqueue API), built the Playing tab `TrackSummaryCard` with CTA/job/failure/section jump states, surfaced localization, and auto-enqueue summaries as soon as TranscriptionManager finalizes transcripts (notification → AI queue) when an AI key is present.
- Pending: Surface summaries inside `TranscriptViewerSheet`, add manual regeneration from transcript context, and polish error copy/empty states before shipping to broader beta group.
