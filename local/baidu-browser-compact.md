# Task: Baidu Browser Sheet Needs Compact Layout

## Summary
- Screenshot reference (2025-11-05 15:27) shows the Baidu file browser sheet occupying too much vertical space for the "Current Path" row and duplicating the "已选择" header that already appears in the footer.
- The user wants the current path display to be more compact and keep only the essential selection summary at the bottom.
- The picker sheet should appear slightly taller by default so more rows are visible without manually dragging.
- Replaced the strip with a minimal caption line that shows only the full path (no “Current Path” title).
- Added a basic `#Preview` so SwiftUI Canvas can show the browser without running the full app.

## Requirements
1. Make the current-path row concise (single line, middle-truncated, smaller typography) while retaining folder icon context.
2. Remove the redundant top "已选择" / selected-count header from `TrackPickerView`; bottom summary remains the single source.
3. Increase the sheet's initial height, e.g., via a taller detent, so the Baidu browser list shows more rows immediately.

## Plan
- [x] Update `BaiduNetdiskBrowserView` row styles for the path display (condensed font, limited line height, subtle caption beneath if needed).
- [x] Remove the `selectionHeader` from `TrackPickerView` and rely on the footer summary.
- [x] Adjust the sheet detents (e.g., `.fraction(0.8)` + `.large`) so it opens higher by default.

## Progress
- [x] Captured request + clarified acceptance criteria.
- [x] Implemented the compact path row plus TrackPicker adjustments.
- [x] Removed the old inline TrackPicker sheet and wired the shared `TrackPickerView` into the project so the improvements actually display.
- [x] Removed redundant "Folder" subtitle and aligned names to the leading edge for clearer scanning.
- [ ] Run a quick UI regression scan via Xcode previews or build (time permitting).
- [ ] Update this doc + PROD entry when complete.
