# AI Tab Integration

## Summary
- Build a dedicated **AI** tab in the Audiobook Player app to manage AI Gateway usage.
- Users can paste their own AI Gateway key, store it in Keychain, browse models, set a default, run quick tests, view credits, and inspect generation metadata.
- 2025-11-08: Credentials block now uses a DisclosureGroup, and the model catalog is grouped by provider prefix (e.g. `deepseek/…`) with collapsible sections and a “current default” summary row.
- 2025-11-08: Default-model summary row now embeds the refresh control, provider expansion states persist via `AppStorage` with providers collapsed by default, a search bar filters models/providers with a localized empty state, and the Model Catalog section lives at the bottom of the tab.

## Requirements
1. Add a fourth tab labeled **AI** in the main TabView.
2. Provide a secure form to enter/validate the AI Gateway key and persist it in Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
3. Fetch `/models`, show metadata, and allow choosing a default model saved in UserDefaults (and synced later if needed).
4. Render model details + quick “Set as default” control for each entry.
5. Provide a chat playground wired to `/chat/completions` for smoke tests, surfacing provider metadata + token usage.
6. Surface `/credits` balance + `/generation` lookup UI (with retries for 404-not-ready state).
7. Reuse the new probe scripts + doc snapshots to keep responses in sync.

## Plan
- [x] Create Keychain storage + client/service wrappers for AI Gateway endpoints.
- [x] Implement `AIGatewayViewModel` to orchestrate credentials, fetches, and UI state.
- [x] Build `AITabView` with sections: Credentials, Model Catalog, Tester, Credits ~~Generation Lookup~~ (lookup hidden for now because the API isn’t live yet).
- [x] Add localization keys + TabView wiring.
- [x] Update docs (ai-gateway + PROD) with implementation status and usage tips.

## Notes
- Reference `local/ai-gateway-openai-compatible.md` for the full API spec and sample payloads.
- `scripts/ai_gateway_probe.py` can be reused to verify responses manually during development.

## Progress
- API key save button now captures SecureField text before validation → the “empty key” alert is gone.
- Model fetch uses the stored Keychain API key, so the catalog populates automatically after a key is verified (no more empty list).
- Soniox configuration moved to the new **TTS** tab; the AI tab now focuses purely on AI Gateway features (credentials → model catalog → chat tester → credits).
