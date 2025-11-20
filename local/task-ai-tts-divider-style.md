# Task: AI & TTS Tab Divider Consistency

**Status**: In Progress
**Date**: 2025-11-12
**Reporter**: User screenshot (AI tab credentials card)

## Problem
- The AI tab credentials card shows separators with mixed lengths (some stretch edge-to-edge, others are inset) inside the disclosure group.
- The speech/TTS tab (Soniox credentials) reuses the same layout and exhibits the exact visual inconsistency.
- Both sections rely on SwiftUI's default grouped `List` styling, which renders a mix of list-row separators and internal disclosure dividers, causing uneven spacing.

## Plan
1. Replace the implicit `DisclosureGroup` content layout with an explicit `VStack` that draws custom dividers so every line spans the same width.
2. Hide the system-provided list separators for those credential sections to avoid double lines.
3. Apply the same helper layout to the TTS tab so both tabs share the fix.
4. Verify by rebuilding the iOS target (and eyeballing in the simulator if time allows).

## Notes
- Keep the stored focus-resign helper so key saving still works.
- Ensure the new layout keeps accessibility labels and button hit areas unchanged.

### 2025-11-12 Update
- Returned to the default `List`/`Section` rows with a shared `CredentialRowModifier` so each field/button/status is its own row, uses consistent padding, and inherits the system separators (full width). This keeps the visuals simple while aligning the lines.
