# Bug: AI Tab Selected Model Summary Shows `(null)` and Crashes Refresh

## Summary
- When refreshing the AI model catalog, the selected model summary row renders `((null))` for the provider suffix.
- The refresh triggers a runtime warning: `String(format:locale:arguments:): Provided argument types ["Swift.String"] do not match the format string's specifiers ...`.
- Occurs because the localized string `ai_tab_selected_model_summary` expects two `%@` placeholders while the UI only supplies the model name.

## Reproduction
1. Open the AI tab with a saved API key and a previously selected model.
2. Pull to refresh or tap the refresh icon.
3. Observe the summary label at the top: `DeepSeek V3.2 Exp ((null))`.
4. Console logs the `NSCocoaErrorDomain Code=2048` format-string mismatch warning.

## Root Cause
- `AITabView.selectedModelSummary` always formatted the localization with a single argument (`displayName`).
- Chinese translation (`%@（%@）`) still required two placeholders; the missing provider caused the fallback string `(null)` and triggered the format warning.

## Plan
1. Audit `AITabView` summary builder and identify available provider metadata.
2. Supply both display name and provider, falling back gracefully when provider data is missing.
3. Verify localization behavior in English/Chinese and ensure no format warnings remain.

## Progress
- ✅ Added `providerDisplayName(for:)` helper that pulls from `ownedBy`, metadata provider, or ID prefix fallback.
- ✅ Updated `selectedModelSummary` to feed both placeholders when provider data exists and fall back to plain name otherwise.
- ⏳ Manual verification on-device after build refresh.

