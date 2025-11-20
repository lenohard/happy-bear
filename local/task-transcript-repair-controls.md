# Task: Transcript Repair Controls Refresh

## Request
- Source: 2025-11-18 screenshot + note from user
- Goal: Compact the auto-select controls in the transcript repair sheet, add third toggle, reposition slider/button, add stats card, shrink the primary select button label.

## Requirements
1. Convert `Show selected only` and `Exclude repaired` buttons into toggles; add a third toggle for selecting all segments/tracks depending on naming (acts as global selection switch).
2. Arrange all three toggles on a single line with concise, small labels.
3. Place the confidence threshold slider and select/unselect button on one horizontal line beneath the toggles.
4. Reduce the font size of the main `Select` button ("选中" in zh-CN).
5. Insert a statistics card summarizing key counts: total segments/tracks, low-confidence matches, repaired segments, currently selected segments, and total selected characters.

## Notes
- Ensure layout adapts for both English and Chinese localizations.
- Keep existing business logic for thresholding but expose new computed stats helpers if needed.
- Consider reusing SF Symbols or text badges for the stats card if space allows.

## Progress Log
- 2025-11-18: Task captured.
- 2025-11-18: Received feedback to remove metric captions and allow collapsing the entire control card to preserve transcript viewport.
