# Task: AI Tab model pricing & default selection UX
Created: 2025-11-17

## Scope
- Fix pricing label to show actual $/1M token numbers (API returns per token).
- Ensure default model selection updates immediately and list scrolls to the active model.
- Collapse all provider groups by default except the currently selected model, and auto-expand the provider if default changes.

## Status
- Pricing fix implemented via a formatter that multiplies by 1e6 and sanitizes raw strings.
- `selectedModelID` now stored in @Published property; UI updates instantly.
- ScrollViewReader auto-scrolls to the default model and expands its provider group; other groups collapsed on first load.
s
