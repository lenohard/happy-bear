# SwiftUI Preview Coverage

## Request
- Ensure each SwiftUI view used in the player has an accompanying Xcode canvas preview so layouts can be tweaked quickly.
- Identify any view files that still lack `#Preview` blocks and add realistic sample data where needed.

## Context
- Most primary views (LibraryView, SourcesView, TrackPickerView, etc.) already have previews.
- Utility components like `FavoriteToggleButton` and full-page favorites list still render without previews, so they're invisible in Canvas today.

## Plan
1. Audit all SwiftUI `View` structs and list the ones that do not declare a preview.
2. Add lightweight `#Preview` blocks with sample data for the missing views, creating preview-specific helpers/mocks as needed.
3. Verify previews compile locally (no missing dependencies) and document the change.

## Progress
- [x] Step 1 — missing previews identified: `FavoriteToggleButton`, `FavoriteTracksView` (and row component)
- [x] Step 2 — added preview coverage plus dedicated harness/mocks for the missing views
- [ ] Step 3 — run `xcodebuild` or an equivalent sanity check (skipped for now; Xcode Canvas will be the first verification touchpoint)

## Notes
- Avoid touching production logic; preview factories should stay under `#if DEBUG` to keep build lean.
- Prefer `.local` sources for mock collections so previews do not require Baidu auth tokens.
