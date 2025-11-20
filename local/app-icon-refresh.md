# App Icon Refresh

## Summary
- Align the launch screen and app bundle icon with the new bear artwork.
- Generate the missing iPhone notification/settings and iPad notification/settings icon sizes.
- Ensure `Contents.json` references all required bitmaps.

## Context
- Reported issue: launch screen shows an outdated book icon despite updating larger assets.
- Missing bitmaps: 20pt 2x/3x, 29pt 2x/3x, 40pt 2x/3x, and 20pt 2x (iPad).

## Plan
1. Inspect current asset catalog and generation script.
2. Produce the missing PNG sizes from the 1024×1024 master.
3. Update `Contents.json` entries to reference new files.
4. Verify no stale artwork remains and document follow-up.

## Progress Log
- 2025-11-06: Initial analysis complete; identified missing sizes and script gaps.

## Related Files
- `AudiobookPlayer/Assets.xcassets/AppIcon.appiconset/`
- `scripts/generate-app-icons.sh`
