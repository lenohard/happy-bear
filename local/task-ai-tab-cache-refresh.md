# Task: AI Tab Cached Models & Credits

## Summary
The AI tab refetches the model catalog and credit balance every time the app launches, causing unnecessary API calls and slower perceived load. Goal: load cached responses by default and only hit the network when the user explicitly refreshes (or after saving a new key).

## Requirements
- Cache the most recent model list and credit balance on disk.
- Pre-populate the AI tab UI with cached data on launch.
- Preserve manual refresh controls so the user can pull fresh data at will.
- Surface a "last updated" indicator so people can tell how stale the cache is.

## Plan
1. Extend `AIGatewayViewModel` with persistence helpers (UserDefaults) for models + credits, including timestamps.
2. Load cached payloads during init so the AI tab starts populated; update cache when refresh succeeds.
3. Update `AITabView` UI to show "last refreshed" info beside existing refresh buttons, plus add localization keys (recorded in `local/new_xcstrings.md`).
4. Document changes here + wire up PROD entry once implemented.

## Progress
- [2025-11-12] Document created and plan drafted. Implementation in progress.
