# Task: Transcription Sheet Process & Context (2025-11-17)

## Request
- When tapping the transcription button, the sheet should show detailed phase updates (downloading, uploading, transcribing, etc.) with progress including downloaded size / total size.
- Provide an input area that lets the user supply additional context to improve STT accuracy; default context should include collection title/description and track title. Pass this string via the Soniox `context` field.

## Notes
- Screenshot reference: clipboard_image_20251117_194442.png.
- Need to surface file download progress while fetching Baidu/external assets.
- Ensure localization for new UI labels.

## 2025-11-17 feedback (new)
- When a transcription has already started for a track, the track row should show an “in-progress” indicator so the user can long-press to open the detail sheet instead of tapping Transcribe again. Add a guard that disables the transcribe action and surfaces a CTA like “View running job”.
- Current TTS tab sometimes shows no active job/indicator even while a sheet is downloading (see screenshot `clipboard_image_20251117_202241.png`). Need to verify the data source: the tab lists `allRecentJobs` (DB-backed) while in-memory `activeJobs` contains the placeholder `downloading/uploading` slot. If `refreshAllRecentJobs()` isn’t called while the sheet is open (or limit/ordering filters it out), the tab stays empty. Plan: drive the active section from `activeJobs` directly, and fall back to `allRecentJobs` for history, so placeholder jobs surface immediately.
- Download feels much slower here than tapping “Download” on the playing card. The transcription sheet uses `URLSession.shared.bytes` and writes **byte-by-byte** into an 8 KB buffer; this is CPU-heavy and disables HTTP range/resume. The cache downloader uses a `URLSessionDownloadTask` + progress KVO with multi-kB chunks. Action: replace `downloadFile` with a chunked stream (e.g., `for try await chunk in bytes.chunks(ofCount: 64*1024)`), or reuse `AudioCacheDownloadManager`/`downloadTask` path for Baidu/external assets to match cache/download speeds.

### Proposed UI/logic changes
- Track list (`TrackDetailRow` / CollectionDetail context menu): show a compact spinner or dot + “Transcribing…” badge when `transcriptionManager.activeJobs` contains this trackId. Context menu should present “View running transcription” leading to `TranscriptionSheet`, and hide the “Transcribe” button while active.
- TTS tab: render the Active section from `activeJobs` (in-memory) so transient download/upload placeholders appear; keep history section backed by `allRecentJobs`. Ensure the badge and auto-refresh timer key off `activeJobs.count` so the tab reflects running work even before Soniox assigns a jobId.
- Networking: swap transcription download helper to chunked writes or reuse cache downloader to close the speed gap with the playing-card download.

### 2025-11-17 implementation notes
- Track rows now receive `isTranscribing` from `transcriptionManager.activeJobs`, render a blue spinner + “transcription_step_transcribing” badge inline, and swap the context-menu action to `transcription_view_running_job` so the user jumps into the sheet instead of starting a duplicate Soniox run.
- TTS tab jobs list now surfaces `transcriptionManager.activeJobs` directly; the Active section no longer waits on `refreshAllRecentJobs()`, so placeholder download/upload jobs show up immediately and the “no active jobs” hint only appears when the queue is empty.
- `downloadFile` in `TranscriptionSheet` batches 64 KB chunks and throttles progress callbacks to ~0.2s intervals (instead of per-byte). This removes thousands of `MainActor` hops and makes STT downloads comparable to the cache/download button speeds.
- Added `TranscriptionManager.beginDownloadJob`/`updateDownloadProgress` so the sheet registers a placeholder job before Baidu download begins (and streams progress to `activeJobs`). This makes the Collection detail badge and the TTS tab show “downloading…” immediately, fixing the missing indicator while the audio bytes are still coming down. Also changed `updateDownloadProgress` to persist the real fraction (0-1) instead of an artificial 0-0.2 window, and `TranscriptionSheet` now only increases `downloadedBytes` from the mirrored job so the progress text never drops back to ~576 KB.
- Fixed: the TTS tab Retry button now re-runs `transcribeTrack` using the original track + job id. Added `db.loadTrack(id:)` to rehydrate the track/collection, retry re-downloads audio (uses cache first, otherwise Baidu token/external URL) and updates the same job instead of calling unimplemented Soniox async polling APIs.
- Transcription downloads now write directly into the playback cache (Baidu tracks): before downloading we create the cache entry, stream into that file, and mark it complete. If the track was already cached by playback we reuse it immediately. Downloads started from the Transcription sheet or Retry are visible on the playing card and won’t re-download on subsequent runs.
- Added cache hit/miss logging to `TranscriptionSheet` + retry manager, and throttled the sheet’s download progress updates so the bar no longer flickers between staged values while the overall job progress continues to update.
