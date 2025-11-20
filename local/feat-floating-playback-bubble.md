# Feature: Floating Playback Bubble

## Overview
A system-wide floating bubble (similar to iOS AssistiveTouch) that provides persistent access to playback controls and the Playing screen from any tab.

## Goals
- **Accessibility**: Allow users to control playback without navigating back to the Playing tab.
- **Space Efficiency**: Replace the traditional bottom "mini-player" bar to save vertical screen real estate.
- **Context Awareness**: Automatically hide when on the Playing screen to avoid redundancy.

## Design Specification

### UI Component
- **Shape**: Circular, ~60x60pt.
- **Content**: 
  - Background: Current Track Artwork (masked to circle).
  - Overlay: Subtle shadow/stroke for contrast.
  - State: Dimmed or overlay icon when paused.
- **Position**: Floats above all other views (ZStack overlay in ContentView).

### Interactions & Gestures
- **Drag**: 
  - User can drag the bubble anywhere on screen.
  - On release, animates and snaps to nearest lateral edge (Left/Right) to avoid blocking center content.
  - **Safe Area**: Respects top/bottom safe areas.
- **Single Tap**: Toggle Play/Pause.
- **Double Tap**: Open **Playing Tab** (Maximize).
- **Long Press**: Show Context Menu.
  - "Hide for this session"
  - "Settings"

### Visibility Logic
- **All Tabs**: Bubble remains visible on all tabs, including the Playing tab.
- **Keyboard**: Should remain above keyboard or move out of way (standard ZStack behavior usually handles "above", but might cover input. Acceptable for MVP).
- **Empty State**: Hidden if no track is loaded/playing.

### Persistence
- **Position**: Remember last X/Y coordinate (relative to edge) across app launches.
- **Preference**: 
  - **Settings Toggle**: "Enable Floating Bubble" (Default: On).
  - **Session Hide**: If hidden via menu, restores on next app launch or via Settings toggle.

## Implementation Status (2025-11-20)

### Completed ✅
- Created `FloatingPlaybackBubbleViewModel.swift` - manages position, snapping, and visibility state
- Created `FloatingPlaybackBubbleView.swift` - UI component with gestures
- Integrated bubble into `ContentView.swift` as overlay
- Added Settings toggle in `SettingsTabView.swift`
- Created shared `Color+Hex.swift` extension
- Fixed Color redeclaration error
- Committed to git: `b6f8453`
- **2025-11-20** – Restored bubble hit-testing/dragging, corrected pause vs play icon logic, and applied a translucent (0.8 opacity) treatment so the bubble feels lighter on top of content.
- **2025-11-20** – Added user-configurable transparency (Settings ▸ Floating Player slider) and replaced the SwiftUI context menu with a centered confirmation dialog so the long-press actions always appear near the middle of the screen. Implemented a custom passthrough long-press recognizer so taps/drags were expected to remain immediate, but simulator testing still shows no drag/tap events being delivered.

- **2025-11-20 Evening** – Fixed the hit-testing/drag issue:
  - **Root cause**: Used `.offset` for positioning, which moved visual content but left layout bounds at (0,0), causing touches outside top-left to be ignored.
  - **Solution**: Switched to `.position` with proper modifier ordering - gestures and hit testing applied to bubble content *before* positioning in global space.
  - **Jitter fix**: Used `DragGesture(coordinateSpace: .global)` to prevent coordinate system shifting during drag.
  - Removed duplicate file `AudiobookPlayer/Views/Components/FloatingPlaybackBubbleView.swift`.
  - All interactions now working: drag, tap, double-tap, long-press, and opacity slider.

- **2025-11-20 Evening** – Fixed bubble visibility:
  - **Bug**: Bubble was hidden when on the Playing tab due to conditional check in ContentView.
  - **Fix**: Removed the `if tabSelection.selectedTab != .playing` condition so bubble stays visible on all tabs.
  - **Result**: Bubble now appears when app starts (if track is loaded) and remains visible across all tabs.

- **2025-11-20 Evening** – Enhanced Bubble UX:
  - **Interaction Feedback**: Added iOS AssistiveTouch-style scale animation (1.15x) when dragging or tapping.
  - **Progress Indicator**: Added a circular progress ring around the bubble that fills up as the track plays.
    - Visuals: Subtle white track with a bright white progress stroke.
    - Logic: Calculates `currentTime / duration`, handles edge cases.
  - **Animation**: Smooth spring animations for interaction and linear animation for progress updates.

### Known Bugs 🐛
None currently.

### Next Steps
- [ ] Verify position persistence across app launches
