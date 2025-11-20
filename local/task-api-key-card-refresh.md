# Task: AI + TTS API Key Card Refresh

## Request
- Date: 2025-11-13
- Source: user message
- Goal: Redesign the API key cards in both AI and TTS tabs so they use a two-line layout.
  - Line 1: shows the key in masked form by default, allows editing inline, and provides an eye toggle to reveal the raw key.
  - Line 2: hosts Save + Edit controls so the user can persist a new key or re-open the inline editor at any time.
  - When displaying the key, mask the middle characters with `...`.

## Notes
- Need parity between AI Gateway key handling and Soniox key handling.
- Current SecureField rows clear once the key is saved, so we cannot show the stored value; we likely need a stored preview state in both view models.

## Plan
1. Update `AIGatewayViewModel` + `SonioxKeyViewModel` to expose a stored key value for preview/editing (mask in UI, but allow reveal with eye toggle).
2. Rebuild the credential rows in `AITabView` and `TTSTabView` into two-line stacks: (a) display/edit + eye toggle, (b) Save/Edit buttons.
3. Ensure Save triggers existing persistence + validation flows, toggles editing mode off on success, and keeps Edit available for future updates.
4. Add localization strings if new labels are required (e.g., Edit Key, Cancel Edit) and update docs/tests if necessary.

## Progress
- 2025-11-13: Logged request and outlined implementation approach.
- 2025-11-13: Added stored-key preview state to AI + Soniox key view models, rebuilt both credential cards with the new two-line layout (masked display/editor row + Save/Edit controls), and wired up show/hide toggles plus editing state transitions.
