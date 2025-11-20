# Task: Localization Repair

## Summary
- Rebuild `Localizable.xcstrings` using Xcode string catalog format so it loads without runtime errors.
- Ensure all localization keys referenced in the SwiftUI views exist with English and Simplified Chinese translations.
- Remove reliance on the legacy `generate_strings.py` file and document the modern workflow.

## Context
- Recent commits deleted `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings` while regenerating the string catalog via the Python script.
- The resulting `.xcstrings` file appears corrupt or incomplete, causing `The data couldn’t be read because it isn’t in the correct format` during build/runtime.
- App now depends entirely on the `.xcstrings` catalog, so any missing/malformed entries break localization loading.

## Plan
1. Audit Swift sources for `Text("…")`, `Label("…")`, `String(localized:)`, and `NSLocalizedString` usages to build the authoritative key list.
2. Compare against the current catalog to locate missing or malformed keys; gather translations (EN + zh-Hans) for the deltas.
3. Rebuild `AudiobookPlayer/Localizable.xcstrings` as a valid string catalog plist, ensure deterministic ordering, and convert to binary via `plutil` for Xcode compatibility.
4. Sanity-check with `plutil -lint`, run a lightweight localization lookup test (Swift or unit) if possible, and document the workflow/next steps here plus `local/PROD.md`.

## Progress
- [ ] Key audit
- [ ] Catalog rebuild
- [ ] Validation & docs

## Notes
- Remember to keep translations culturally appropriate; prefer concise UI strings.
- After finishing, consider deleting or archiving `generate_strings.py` if it’s no longer the source of truth.
