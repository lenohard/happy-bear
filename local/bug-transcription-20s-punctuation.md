# Bug: 20s Segment Limit Should Honor Punctuation

## Description
- Current transcription segmentation combines Soniox tokens until speaker changes, punctuation ends the sentence, or the 20-second cap is hit.
- When only the duration limit fires, the code finalizes immediately which can split a Chinese phrase in half because it ignores nearby punctuation like `，` or `,`.
- Requirement: when enforcing the 20s cap, prefer breaking at the nearest punctuation mark under the threshold—especially commas—so we avoid chopping phrases mid-token unless no punctuation exists.

## Plan
1. Inspect `TranscriptionManager.groupTokensIntoSegments` to understand how it stores in-progress segments.
2. Track token-level metadata so we know which timestamps correspond to punctuation we can safely split on.
3. When the duration constraint is reached, search backward for the latest comma-like punctuation within the segment; split there if found, otherwise fall back to the current hard cut.
4. Regression-test by exercising the segmentation helper (unit or targeted sample) to ensure punctuation-aware splitting behaves as expected for Chinese and English cases.

## Progress
- 2025-11-17: Logged bug and outlined plan after user report.
- 2025-11-17: Refactored `groupTokensIntoSegments` to keep per-token metadata, prefer punctuation under the 20s cap, and confirmed the app builds via `xcodebuild`.
