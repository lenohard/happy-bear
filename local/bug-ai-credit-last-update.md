# Bug: AI tab credit "last updated" loop (2025-11-20)

## Report
- 2025-11-20: User reports the AI tab 余额 card shows "last update" text updating roughly once per second, burning CPU/energy.
- They only expect the balance timestamp to change when the view first appears (auto-fetch) or when they press refresh manually.

## Observations / Notes
- `AITabView.lastRefreshDescription` generates a relative string using `RelativeDateTimeFormatter` with `relativeTo: Date()`.
- `AIGenerationManager` polls the job tables every second, which publishes state changes and forces the AI tab view hierarchy to rebuild, even if the balance data is untouched.
- Because the helper recomputes against `Date()`, the balance label changes every rebuild ("1s ago", "2s ago", ...), which makes it look like the app re-fetches and wastes work.
- We can stabilize the UI by formatting `lastCreditsRefreshDate` once (absolute date/time) so repeated renders return the same string until the underlying `Date` changes.

## Plan
1. Replace the relative formatter in `AITabView.lastRefreshDescription` with a reusable absolute `DateFormatter` (e.g., `.medium` date + `.short` time) so the formatted string only depends on the stored refresh date.
2. Keep using the existing localized template `ai_tab_last_updated_template` to prefix "最近更新:" and feed it the formatted timestamp.
3. Verify by re-running the AI tab in Preview (or logging) to ensure the text no longer changes every second while idle, and that manual refresh still updates the timestamp.

## Status / To-do
- [x] Update `AITabView.lastRefreshDescription` implementation.
- [ ] Smoke check in simulator/preview if feasible; otherwise reason about logic and note follow-up verification for the user.
