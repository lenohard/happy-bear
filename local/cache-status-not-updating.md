# Bug: Cache status never updates while streaming

## Report
- **Date**: 2025-11-10
- **Reporter**: User (screenshot of Cache Settings sheet)
- **Symptom**: While audio is actively playing, the Cache Settings view still displays the current track as `not_cached` ("未缓存") and `0 B of 13.5 MB cached`. Download progress never moves.
- **Expectation**: Background caching should begin automatically once playback starts so the UI reflects partial/complete cache state without requiring extra taps.

## Initial Notes
- Current caching pipeline only runs when `AudioPlayerViewModel.cacheTrackIfNeeded(_:)` is invoked (Download for offline button).
- Auto-caching hook described in `local/Cache.md` ("When user starts playback at position X, cache from X onward in background") never runs.
- Need to evaluate best place to trigger `startBackgroundCaching` automatically and avoid duplicating downloads.

## Plan
1. Confirm code path that should trigger caching automatically during playback.
2. Update `AudioPlayerViewModel.play(...)` / `playDirect(...)` to invoke background caching when track comes from Baidu Netdisk and token is available.
3. Guard against duplicate downloads and ensure cache metadata isn't reset unnecessarily.
4. Verify UI now reflects partial/complete cache states for the actively playing track.

## TODO
- [x] Hook auto-caching into playback pipeline (`AudioPlayerViewModel.autoCacheIfPossible`, invoked from `play`/`playDirect`)
- [x] Prevent duplicate download kicks / handle metadata reuse (skip when download already active, reuse metadata unless missing)
- [ ] Smoke test on simulator + capture console logs if needed
- [ ] Update documentation / PROD entry when fixed

## Implementation Notes
- Added `autoCacheIfPossible(_:)` to silently launch `startBackgroundCaching` whenever a Baidu track begins playback (both library + direct play flows).
- `AudioCacheDownloadManager` now exposes `isDownloading(trackId:)` so the view model can avoid stomping metadata while a download is already active.
- `startBackgroundCaching` skips recreating cache files when metadata exists, updates TTL metadata instead, and restarts download only when safe. Existing downloads cause us to just attach a new tracker.

## Testing
- `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -sdk iphonesimulator -quiet build` (warnings pre-existing; build succeeds)
