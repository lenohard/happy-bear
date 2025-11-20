# Task: Default Tab to Playing
Created: 2025-11-17

## Request
- User wants the Playing tab to be the first tab shown when launching the app instead of Library.

## Context
- Tab order currently: Library, Playing, AI, TTS, Settings.
- Need to adjust initial TabView selection/persistence logic so app opens on Playing tab while keeping manual tab switching behavior unchanged.

## Plan
1. Locate the TabView selection binding (likely in `ContentView.swift` or `RootTabView`).
2. Update the default selection constant or stored value to `.playing` without disrupting stored preferences.
3. Ensure state restoration (last tab) still works if applicable; otherwise confirm default is only used when no stored tab exists.
4. Test on simulator to confirm the Playing tab is active at launch.

## Status
- Default tab changed to Playing by setting `TabSelectionManager.selectedTab` initial value to `.playing`.
