# Feature: Title Edit

**Status**: 🟢 Ready for Review  
**Created**: 2025-11-06

---

## Context

User request (2025-11-06): Enable editing the title of an individual track directly from the collection detail page.

### Current Understanding
- Edits happen inside the collection detail screen only.
- Track title edits are scoped to the current collection (local override, no cross-collection propagation).
- Collection title itself also needs to be editable from the same screen.
- Title max length: 256 characters; no special charset constraints beyond SwiftUI defaults.
- Autosave on change (no explicit confirmation); no history or undo requirements.

---

## Decisions & Scope
- Track title edits remain local to the current collection; they update `AudiobookTrack.displayName` without touching `filename`/`location`, so Baidu streaming and caching keep working.
- Collection title uses a trailing `Menu` (“…”) in the summary card; tracks expose a trailing swipe `Rename`.
- Renames clamp to 256 characters and trim whitespace; empty results are ignored.
- Rename sheets reuse a single `RenameEntryView` with focused `TextField`, auto-cancel on dismissal, and reuse `cancel_button`/`ok_button`.
- Autosave happens on dismiss; no history or undo.

---

## Implementation Summary
- Library layer: `LibraryStore.renameCollection` / `renameTrack` update in-memory collections, clamp to 256 chars, persist snapshot, and enqueue sync save.
- UI: `CollectionDetailView` summary card hosts an “…” menu for renaming the collection; track rows expose trailing swipe `Rename`.
- Shared rename sheet component (`RenameEntryView`) focuses the text field, enforces length, trims whitespace, and auto-cancels on swipe dismissal.
- Localization updated via `generate_strings.py` to cover the handful of new labels (EN + 简体中文).
- Autosave happens immediately after submit; no additional buttons or confirmations were added.

---

## Next Steps
1. Manual validation on device/simulator: rename collection & several tracks (including whitespace-only + >256 chars cases) and relaunch to confirm persistence.
2. Confirm no regressions for removal/favorite swipe actions alongside new rename option.
3. Prepare commit once testing passes.
