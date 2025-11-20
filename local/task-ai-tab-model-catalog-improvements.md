# Task: AI Tab Model Catalog Improvements

## Summary
- User wants the "Refresh Models" control moved onto the current default model row as a trailing button.
- Model directory should remember expanded sections; when re-opening, previously expanded sections must stay open instead of collapsing everything.
- Add search support inside the model directory list to quickly filter models by name or provider keyword.

## Requirements
1. Convert the default model summary row into a horizontal layout with a trailing refresh icon/button.
2. Persist catalog DisclosureGroup expansion states so the UI re-opens with prior selections expanded.
3. Provide an inline search field (case-insensitive) that filters providers and model entries.
4. Keep UX consistent across English/Chinese localizations.
5. Update docs + changelog with the new behavior.

## Plan
- [x] Audit `AITabView` / catalog components to understand current layout and state handling.
- [x] Implement UI/layout changes plus new state for refresh/search, persist expansion preferences, and update localization keys.
- [x] Add tests or manual verification notes, update docs (`ai-tab-integration.md`, `PROD.md`), and prepare for commit.

## Notes
- Confirm whether expansion state should persist app-wide (UserDefaults) or per-session view state; default to `AppStorage` for durability unless code shows a preferred pattern.
- Re-use existing refresh logic and ensure there is still an accessible button (touch target >= 44 pt).

## Progress
- Refactored `modelsSection` so the default-model summary row now hosts a trailing “Refresh Models” button, keeping the action co-located with the summary.
- Added a rounded TextField search bar plus filtering logic (`filteredModelGroups`) so providers/models can be narrowed by provider name, model id/name, or description; surfaces a localized empty-state message when nothing matches.
- Swapped temporary `@State` storage for `AppStorage` + JSON-backed sets to persist DisclosureGroup expansion, ensuring provider sections stay open between visits.
- Introduced new localization keys (`ai_tab_models_search_placeholder`, `ai_tab_models_search_no_results`) with English and Chinese translations.
- Manual verification: not run (UI work requires Simulator); needs on-device check for persistence + search UX.
- Default provider DisclosureGroups now start collapsed (but persist when a user reopens), the model catalog section was moved to the bottom of the AI tab, and separators were hidden around the summary/search rows to match the rest of the list styling.
- Reset the persisted expansion keys (`ai_tab_*_v2`) so everyone gets a fully-collapsed default state even if they had previously expanded providers.
