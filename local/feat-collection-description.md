# Task: Collection Description Display & Editing

## Summary
Surface each collection's description inside `CollectionDetailView` and let users edit that text alongside the title so notes/translations are visible once a set of tracks is imported.

## Requirements
- Show the saved description underneath the collection title in the detail summary without truncating the first line.
- Provide an edit affordance that lets users update both the title and description in one place.
- Persist description changes through `LibraryStore` so GRDB + JSON storage and any sync engines stay consistent.
- Localize any new labels / prompts that expose the description editor.

## Plan
1. Audit the existing summary section in `CollectionDetailView` and ensure descriptions render with the right typography + spacing (fall back gracefully if absent).
2. Replace the collection rename sheet with a two-field editor (title + description), wire it to a `LibraryStore` API that updates both properties atomically, and store state for the drafts.
3. Add the necessary localization entries to `local/new_xcstrings.md`, then regression test editing and favorites interactions in the detail view.

## Progress
- [2025-11-17] Created task doc, captured requirements/plan, and began implementation.
- [2025-11-17] Added collection description editor (title + description) in `CollectionDetailView`, hooked to `LibraryStore.updateCollectionDetails`, and showed description/add placeholder in the summary section.
- [2025-11-17] Updated localization stubs in `local/new_xcstrings.md` and ran `xcodebuild -scheme AudiobookPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (build succeeded; only existing preview/deprecation warnings surfaced).
