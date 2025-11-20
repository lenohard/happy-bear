# Feat: Collection Detail Auto-Focus on Last Played Track

## Request
- **Date**: 2025-11-10
- **Source**: User
- **Summary**: When opening a collection detail view, automatically scroll the list to the track that was last played (or the one that is currently playing if playback is active). This saves users from manually hunting for the in-progress track.

## Context & Notes
- `AudiobookCollection` already stores `lastPlayedTrackId`, and the `AudioPlayerViewModel` exposes the actively playing track with `currentTrack` + `activeCollection`.
- `CollectionDetailView` renders tracks via a `List`/`ForEach`, so we can use `ScrollViewReader` or `.scrollPosition` to programmatically bring a row into view.
- Need to ensure the scroll happens once per appearance and only after data + filtering are ready; avoid fighting user-driven scrolling.

## Plan
1. Add state to track the pending focus track ID and whether the auto-scroll already happened for the current collection.
2. Compute the preferred target by prioritizing the actively playing track (when the audio player's active collection matches) and falling back to `lastPlayedTrackId` if available in the current dataset.
3. Wrap the track list in a `ScrollViewReader`, and trigger a smooth `scrollTo` once the target exists inside `filteredTracks`.
4. Reset the auto-focus state when the collection ID changes so the behavior repeats when users switch between collections.

## TODO
- [x] Add `pendingAutoFocusTrackId`/`didAutoFocusTrack` state + helper methods to `CollectionDetailView`.
- [x] Wrap the tracks `List` body inside a `ScrollViewReader` and perform the initial `scrollTo` with animation once the target is resolved.
- [x] Ensure transcript loading / playback recording flows remain unaffected.
- [x] Build to confirm there are no compiler errors; capture any new warnings.

## Implementation Notes
- Added internal auto-focus state + helpers in `CollectionDetailView.swift` to resolve and remember the preferred track (active > last played) and to reset that state when users switch collections.
- Wrapped the track list inside a `ScrollViewReader`, hooked up observers for track/filter changes, and scroll with animation exactly once per appearance.
- Rows now expose stable `.id(track.id)` values so `scrollTo` can find them reliably.
- Auto-focus recomputes until it succeeds, so if the collection data arrives late or the user clears a search filter, the track will still snap into view.

## Testing
- `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -sdk iphonesimulator -quiet build`
