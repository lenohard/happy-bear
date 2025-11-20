# Large Import Scalability

## Summary
- **Problem**: Importer fetches entire Baidu directory tree into memory, enforces a hard 500-track cap, and stalls UI for big folders.
- **Goal**: Stream/paginate imports, remove artificial caps, and keep the progress UI responsive.

## Ideas
- Implement Baidu API pagination with lazy sequences.
- Provide incremental progress feedback (tracks discovered vs. selected).
- Allow background scan with cancellable tasks.

## Notes
- Depends on `CollectionBuilderViewModel`.
- Coordinate with cache prefetch logic once imports grow beyond 500 tracks.
