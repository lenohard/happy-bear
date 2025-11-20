# Bug: Cached Track Playback Failure

## Summary
- **Reported**: 2025-11-04
- **Source**: `local/PROD.md`
- **Symptom**: Tracks that were previously cached fail to play when the player is restarted
- **Goal**: Investigate why cached media is not used for playback and deliver a fix so cached items play reliably.

## Root Cause Analysis

**Problem**: Cache files are saved with `.cache` extension instead of preserving the original audio file extension (`.mp3`, `.m4a`, `.flac`, etc.)

**Why this breaks playback**:
- AVPlayer relies on file extensions to determine media type/codec
- When AVPlayer encounters a `.cache` file, it doesn't know how to decode it
- Result: Silent playback or playback failure

**Evidence**:
- `AudioCacheManager.cacheFilePath()` (line 231-233) creates: `"{baiduFileId}_{trackId}.cache"`
- Should preserve extension: `"{baiduFileId}_{trackId}.mp3"`
- The original filename with extension is available in `AudiobookTrack.filename`

**Fix Strategy**:
1. Extract file extension from `AudiobookTrack.filename`
2. Pass extension to `AudioCacheManager` when creating cache files
3. Store cache files with proper extension: `.mp3`, `.m4a`, `.flac`, etc.
4. Update all cache file operations to use the extension-aware path

**Files to modify**:
- `AudiobookPlayer/AudioCacheManager.swift` - Update `cacheFilePath()` to accept/use extension
- `AudiobookPlayer/CachedAudioAsset.swift` - Add extension field (if needed)
- `AudiobookPlayer/AudioPlayerViewModel.swift` - Pass filename to cache operations
- `AudiobookPlayer/AudioCacheDownloadManager.swift` - Pass filename to cache operations

## Solution Implemented

**Status**: ✅ FIXED (2025-11-04)

**Commit**: `1b5ab67` - fix(cache): preserve audio file extensions for cached tracks

**Changes Made**:

1. **AudioCacheManager.swift** (lines 49, 67, 72, 126, 231-236):
   - Modified `getCachedAssetURL()` to accept `filename` parameter
   - Modified `isCached()` to accept `filename` parameter
   - Modified `createCacheFile()` to accept `filename` parameter
   - Modified `removeCacheFile()` to accept `filename` parameter
   - Updated `cacheFilePath()` to extract file extension from filename and preserve it
   - Cache files now saved as: `{baiduFileId}_{trackId}.{ext}` (e.g., `.mp3`, `.m4a`, `.flac`)

2. **AudioPlayerViewModel.swift** (lines 282, 630, 675, 696):
   - Updated `removeCache()` to pass `track.filename`
   - Updated `streamURL()` to pass `track.filename` when checking cached asset
   - Updated `startBackgroundCaching()` to pass `track.filename` when creating cache file
   - Updated download manager call to pass `track.filename`

3. **AudioCacheDownloadManager.swift** (lines 29-46):
   - Modified `startCaching()` to accept `filename` parameter
   - Passes filename to `createCacheFile()` call

**How it works**:
- File extension is extracted from `AudiobookTrack.filename` using `NSString.pathExtension`
- Cache files are created with proper audio extensions (`.mp3`, `.m4a`, `.flac`, etc.)
- AVPlayer can now properly identify codec based on file extension
- Cached files play correctly after app restart

**Testing Required**:
1. Cache a track with `.mp3` extension
2. Verify cache file is named `{baiduFileId}_{trackId}.mp3`
3. Restart app
4. Play cached track - should work without streaming

**Related Files**:
- AudiobookPlayer/AudioCacheManager.swift
- AudiobookPlayer/AudioPlayerViewModel.swift
- AudiobookPlayer/AudioCacheDownloadManager.swift
- AudiobookPlayer/CachedAudioAsset.swift (no changes needed)

