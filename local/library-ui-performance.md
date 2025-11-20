# Library UI Performance

## Summary
- **Problem**: Lists recompute expensive derived values (sorting, size aggregation) on each render, which will lag with thousands of tracks.
- **Goal**: Cache derived data, move heavy work off the main thread, and ensure SwiftUI lists remain smooth at scale.

## Potential Work
- Maintain pre-sorted track arrays / computed properties in the store layer.
- Precompute collection summaries (track count, total size) when data changes rather than during view rendering.
- Profile search filtering; consider lower-level search indexes if needed.

## Status
- TODO – optimization ideas captured for follow-up.
