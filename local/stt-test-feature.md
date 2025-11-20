# Soniox Test Feature - TTSTabView Enhancement

## Overview
Added a test transcription feature to the TTS (语音) tab that allows users to test their Soniox API key with a sample audio file (`test-1min.mp3`).

## Problem Solved
The test button section was not appearing even for users who had already configured the Soniox API key before the feature was implemented. This was because `keyExists` state was only loaded in the ViewModel's `init()` method, which runs once at initialization.

## Solution
Added a `.task` modifier to the NavigationStack that calls `refreshKeyStatus()` when the view appears, ensuring the test section becomes visible for users with pre-configured keys.

## Changes Made

### Files Modified
1. **`AudiobookPlayer/AITabView.swift`** - TTSTabView struct
   - Added 3 new @State variables for test management
   - Added test section (conditional, appears when key exists)
   - Added `testTranscription()` async function
   - Added `.task` modifier to refresh key status on view appear

2. **`AudiobookPlayer/SonioxKeyViewModel.swift`** - SonioxKeyViewModel class
   - Added public `refreshKeyStatus()` method
   - Allows external views to reload key status from Keychain

### Key Implementation Details

#### 1. View State Variables
```swift
@State private var isTestInProgress = false
@State private var testResult: String?
@State private var testError: String?
```

#### 2. Test Section (Lines 405-445)
Only visible when `sonioxViewModel.keyExists == true`
- Test button with play icon
- Progress indicator during transcription
- Result display (green checkmark on success)
- Error display (red warning on failure)

#### 3. View Initialization Fix (Lines 448-451)
```swift
.task {
    await sonioxViewModel.refreshKeyStatus()
}
```
This ensures existing keys are detected when the view first appears.

#### 4. testTranscription() Workflow
1. Retrieves API key from Keychain
2. Locates test audio file (`test-1min.mp3`)
3. Uploads to Soniox API
4. Creates transcription with language hints ["zh", "en"]
5. Polls for completion (max 120 seconds)
6. Displays transcript or error

## Testing

To verify the fix works:
1. Close and reopen the app
2. Navigate to TTS tab (语音)
3. The test section should now appear below credentials
4. Click "Test with sample audio"
5. App will transcribe the 1-minute test file

## Build Status
✅ **Successful** - Both files compile without errors
- `AITabView.swift` - No syntax errors
- `SonioxKeyViewModel.swift` - No syntax errors
- Pre-existing `TranscriptViewModel.swift` errors are unrelated

## Files Modified / Created
- ✏️ `AudiobookPlayer/AITabView.swift` (Enhanced TTSTabView)
- ✏️ `AudiobookPlayer/SonioxKeyViewModel.swift` (Added refreshKeyStatus)
- 📝 `local/stt-test-feature.md` (This documentation)

## UI/UX Flow

```
User navigates to TTS tab (语音)
    ↓
View loads and calls refreshKeyStatus()
    ↓
If key exists in Keychain:
    ✅ Test section appears
    ✅ "Test with sample audio" button visible
    ↓ (User clicks test button)
    🔄 Progress spinner appears
    🔄 App uploads test-1min.mp3
    🔄 Waits for Soniox transcription (max 2 min)
    ✅ Shows result or ⚠️ shows error
```

## Error Handling
All transcription errors are caught and displayed:
- Missing/invalid API key
- File not found
- Network errors
- Server errors (rate limiting, auth errors, etc.)
- Transcription timeout
- Parsing/decoding errors

## No Breaking Changes
- Existing functionality unchanged
- Only adds new section when key exists
- Backward compatible with previous key storage

## Future Improvements
- [ ] Add language selection dropdown (currently fixed to ["zh", "en"])
- [ ] Add test history/results caching
- [ ] Add ability to choose different test files
- [ ] Add confidence score display from transcript tokens
- [ ] Add speaker diarization toggle

