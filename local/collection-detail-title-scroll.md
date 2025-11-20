# Task: Collection Detail Title Scroll

## Request
- Shrink track title text in CollectionDetailView so longer names fit.
- Change interaction so tapping the title triggers an auto-scroll marquee instead of toggling playback.
- Restrict play/pause behavior to the explicit play control only.

## Plan
- [x] Inspect current track row layout and identify where taps trigger playback.
- [x] Introduce a dedicated play/pause button and replace the text with a ticker view.
- [x] Add localization entries for new accessibility hints and provide them via `local/new_xcstrings.md`.
- [ ] Verify layout visually in code (no simulator run per instructions) and document changes here.

## Status 2025-11-11
- Track rows now render titles through `TrackTitleTicker` with a dedicated transport button; playback toggles only happen via the play/pause icon.
- Reworked ticker: base label hides while marquee animation runs, overlay renders the full text twice to ensure a seamless loop, and state resets after the scroll. Ellipsis no longer scrolls—users now see the full title content.
- Ticker logic lives in `AudiobookPlayer/CollectionDetailView.swift:861`; no simulator run per instructions.

## Notes
- Title tap should only animate scrolling; playback must not start/stop from the text area.
- Ensure ticker animation only runs on demand to avoid distracting motion.
