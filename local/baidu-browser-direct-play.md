# Feat: Baidu Browser Direct Playback

**Created:** 2025-11-07
**Status:** In progress – implementation underway

## Request Summary
- Enable tapping an audio file inside the Baidu Netdisk browser to start playback immediately without creating a collection.
- Ensure the Playing tab surfaces this ad-hoc playback session so users can pause/seek/skip without importing the folder first.
- Clarify how playback state should be stored given these tracks are not tied to an existing `AudiobookCollection`.

## Goals
1. Single-tap streaming from `BaiduNetdiskBrowserView` with the same buffering/caching pipeline used by library tracks.
2. Minimal persistence: avoid polluting the main library/GRDB tables when the user just wants a quick listen.
3. Preserve UX consistency in `PlayingView` (timeline, metadata, cache controls) even when no collection context exists.
4. Leave room to convert a “temporary” listen into a permanent collection later.

## Constraints & Considerations
- `AudioPlayerViewModel` currently assumes every track belongs to an `AudiobookCollection` pulled from `LibraryStore` for both UI and progress persistence.
- `PlayingView` searches `library.collections` to populate the live card and listening history; without a collection the UI would go blank.
- `LibraryStore.recordPlaybackProgress` writes into SQLite/JSON; we should avoid creating phantom collections for one-off streaming because it complicates sync and history.
- Remote commands / Now Playing metadata expect a collection + track pairing for cover art and labels.

## Proposed Architecture

### 1. Temporary Playback Capsules
- Introduce `TemporaryPlaybackContext` struct that mirrors the subset of `AudiobookCollection`/`AudiobookTrack` needed for playback (title, artwork, source enum, track list).
- Store it on `AudioPlayerViewModel` as `ephemeralContext: TemporaryPlaybackContext?` and update `activeCollection` to point at a synthetic `AudiobookCollection` when one exists. That keeps existing APIs working with minimal churn.
- Mark the synthetic collection via `isEphemeral: Bool` or by extending `AudiobookCollection.Source` with `.ephemeralBaidu(path:String)` so downstream code knows it should not be saved to GRDB.

### 2. Storage Strategy
- Do **not** insert temporary sessions into `LibraryStore.collections`.
- Persist lightweight progress to a dedicated `EphemeralPlaybackStore` (e.g., JSON blob under `Application Support/ephemeral_playback.json`) so we can resume if the user switches tabs mid-playback but discard it on relaunch.
- Cache downloads still live under `AudioCacheManager` keyed by Baidu FSID/MD5, so repeated plays benefit from the existing ten-day TTL.

### 3. Triggering Playback from Browser
- Extend `BaiduNetdiskBrowserView` usage inside `SourcesView` so `onSelectFile` builds a `TemporaryPlaybackContext` from the tapped entry (single-track playlist for now, future multi-select can append siblings).
- Call a new `audioPlayer.playDirect(baiduEntry:token:)` that fabricates an `AudiobookTrack` with `location = .baidu(fsId:path:)`, injects it into `playlist`, and sets `activeCollection` to the synthetic capsule.
- Ensure we still require a valid Baidu token; otherwise surface the existing auth prompt.

### 4. Playing Tab Representation
- Update `PlayingView` lookup logic: if `audioPlayer.activeCollection` is ephemeral, bypass `library.collections` search and use `audioPlayer.ephemeralContext` for titles, artwork placeholder, and progress slider.
- Hide actions that depend on a persisted collection (e.g., “Open collection”, “Favorite track”, history list entry) and replace with inline badges like “Streaming direct from Baidu Browser”.

### 5. UX Edge Cases
- **Switching Contexts:** starting playback from a real collection should clear the ephemeral context; vice versa, direct playback should pause any queued library tracks.
- **Background Remote Commands:** ensure `updateNowPlayingInfo()` uses the synthetic metadata so lock screen controls continue working.
- **Resume Behavior:** if the user pauses and leaves the Sources tab, the Playing tab remains functional. On app relaunch we can drop the ephemeral session—documented behavior.
- **Conversion Opportunity:** offer a “Save to Library” CTA on the Playing card that pre-selects the file’s parent folder inside `CreateCollectionView`.

## Implementation Checklist (WIP)
1. ✅ Data model: `TemporaryPlaybackContext` struct plus `AudiobookCollection.Source.ephemeralBaidu`
2. ✅ `AudioPlayerViewModel` additions: playlist injection, ephemeral state, `playDirect(entry:token:)`, guard persistence calls.
3. ✅ `PlayingView` UI fallbacks for ephemeral sessions.
4. ✅ `SourcesView` wiring: trigger direct play with auth validation and present “Save to library” action.
5. ◻️ Optional: lightweight storage for last ephemeral session (not persisted across launches initially).

## Build Fix – 2025-11-07
- Patched `AudiobookCollection.Source` integrations (`GRDBDatabaseManager`, `LibraryStore`) so the new `.ephemeralBaidu` case serializes cleanly and is treated as read-only when editing collections.
- `xcodebuild -scheme AudiobookPlayer -destination 'platform=iOS Simulator,name=iPhone 17' build` now succeeds locally.
- Added direct-play controls inside `SourcesView`’s Netdisk browser: tapping an audio file now calls `audioPlayer.playDirect`, shows a sheet with “Play Now”/“Save Parent Folder” actions, and surfaces friendly errors when the user is signed out or chooses an unsupported format.
- The Playing tab now renders ephemeral sessions directly from `AudioPlayerViewModel`: it shows the live timeline/controls even when the track doesn’t exist in `LibraryStore`, hides favorite/history actions, and exposes a “Save Folder to Library” CTA that opens `CreateCollectionView` pre-filled with the Baidu parent folder.
- Remaining work stays focused on optional ephemeral persistence before we can mark the feature complete.

## Open Questions
- Do we need multi-track queue support when playing from search results (e.g., auto-play next sibling file)? **No – single-track playback is sufficient for this iteration.**
- Should direct-play sessions record listening history? (Probably no, to keep history tied to curated collections.) **Confirmed no, keep history scoped to saved collections.**
- When the user taps “Save to Library”, do we reuse the same temporary track metadata or re-run the full collection builder for consistency? **Re-run the full builder to stay consistent with normal imports.**
