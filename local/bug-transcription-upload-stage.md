# Bug: Transcription sheet stalls after download on iPhone

- **Reported by**: user (2025-11-20)
- **Environment**: iOS build on device (iPhone); macOS Catalyst build works
- **Symptom**: Transcription sheet shows *Downloading* forever. The track downloads successfully, but the UI never advances to *Uploading*; after a long wait the sheet presents a generic network error. Mac build transitions through all stages normally.

## Reproduction
1. On iPhone, open a track in the Library → tap *Transcribe*.
2. Wait for the cache download to finish.
3. Observe that the stage indicator remains at *Downloading*; upload never starts.
4. Eventually an error alert displays ("network wrong" per user report).

## Expected
- Stage should switch to *Uploading* immediately after the cache download ends, and the Soniox upload job should begin.

## Notes & Hypotheses
- `TranscriptionSheet` currently mutates `@State` properties (stage, progress, downloadedBytes) from non-main threads inside async `Task`s. iOS is stricter about "Publishing changes from background threads"; this might block stage updates or drop them entirely while macOS tolerates it.
- Lack of granular logging makes it difficult to see whether download → upload handoff or Soniox API calls are failing on device.

## Plan
1. Add structured `os.Logger` instrumentation across the sheet + `TranscriptionManager` (download completion, upload start, Soniox job IDs, poll status changes, errors).
2. Ensure every stage/byte/progress mutation in `TranscriptionSheet` happens on the main actor and logs the transition reason (so we can prove whether UI state actually advances on device).
3. Surface placeholder/job mirroring info in logs for parity between sheet + manager.
4. Re-test locally (macOS simulator) to confirm no regressions; rely on device logs for iPhone once deployed.

## TODO / Tracking
- [x] Add logger + main-actor guarded stage transitions in `TranscriptionSheet`.
- [x] Add logger + detailed lifecycle logs in `TranscriptionManager` (download placeholder, upload, Soniox polling, errors).
- [ ] Verify logs appear in Xcode console and note any additional warnings.

## Work Log
### 2025-11-20
- Added `os.Logger` instrumentation plus `setStage` helper to `TranscriptionSheet` so every lifecycle hop (download/upload/transcribe/etc.) is logged with track + job IDs.
- Guarded all `@State` mutations behind `MainActor.run` hops to avoid the background-thread publishing issues suspected of blocking stage transitions on iPhone.
- Extended the mirrored job watcher to log when it attaches/detaches from a manager job, along with the job’s reported status/progress.
- Instrumented `TranscriptionManager` for placeholder creation, download progress milestones, upload completion, Soniox job IDs, polling status changes, completion/failure, and cleanup.
- Verified the project builds via `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`; existing warnings remain confined to `AudioPlayerViewModel` and other pre-existing files.
