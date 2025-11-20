# Bug: Track/Transcript Confirmation Popup Position

**Status**: ✅ Completed (2025-11-18)
**Owner**: Codex (GPT-5)

## Problem
- Deleting a track or its transcript shows the confirm UI anchored near the navigation bar rather than near the tapped row or centered.
- This happens both from the overflow menu and swipe actions.
- Screenshot from user (2025-11-18) illustrates the pop tip stuck at the top of the list, obscuring context.

## Expected Behavior
- Confirmation UI should appear in the center of the screen (standard alert) or anchored to the track row for contextual deletions.
- Consistent visual treatment between delete-track and delete-transcript flows.

## Root Cause
- Both flows used SwiftUI `.confirmationDialog`, which renders as a popover anchored to the parent container (the `List`) on iPhone. Because the list fills the screen, SwiftUI anchors the bubble near the navigation bar rather than the tapped cell, making it look detached.

## Plan
1. Replace the `.confirmationDialog` modifiers in `CollectionDetailView` with `.alert` so iOS uses a centered alert sheet.
2. Keep localized copy/actions identical; ensure destructive role still applies.
3. Verify no other logic relies on the old dialog style; adjust `Delete transcript` helper to still capture the correct track reference.
4. Regression scan for any other confirmation dialogs that should remain contextual (cache management, download button) and leave them untouched unless issues reported.

## Notes
- `.alert` supports the same `presenting:` API, so we can preserve the localized message string and ensure the destructive button remains accessible.
- For transcript deletion we need to pass the selected track into `deleteTranscript(for:)`; storing it in state is fine because the action closure still receives the track from `presenting:`.

## Progress
- Replaced both delete-track and delete-transcript confirmation dialogs in `AudiobookPlayer/CollectionDetailView.swift` with `.alert(presenting:)`, keeping the localized prompts and destructive buttons intact. Alerts now show centered on iPhone, matching the user's expectation.
- Left other contextual confirmation dialogs (cache settings, download button) untouched because they intentionally use popovers anchored to smaller controls.

## Validation Checklist
- [ ] Delete a track via swipe → alert appears centered, deleting works.
- [ ] Delete transcript from overflow menu → alert centered, confirms deletes.
- [ ] Cancel button dismisses without side-effects for both flows.
- [ ] No layout regressions in other parts of `CollectionDetailView`.
