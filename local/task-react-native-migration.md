# React Native Migration Task

**Created**: 2025-11-12  
**Owner**: Code (LLM)

Central log for the multi-session effort to port the SwiftUI audiobook player to the React Native + Tamagui stack described in `local/react-native-migration-plan.md`.

---

## Objectives
- Stand up a dedicated Expo + TypeScript workspace inside this repo for ongoing RN feature work.
- Incrementally port core modules (library, playback, Baidu integration, STT, AI) following the migration roadmap.
- Capture progress, blockers, and design choices so future sessions can resume instantly.

## Current Status (2025-11-13)
- ✅ Reviewed `local/react-native-migration-plan.md` for scope + sequencing.
- ✅ Bootstrapped Expo TypeScript project at `react-native-app/` via `npx create-expo-app` (blank template).
- ⚠️ Removed `node_modules/` post-init to avoid bloating the repo; rerun `npm install` before development.
- ✅ Reinstalled dependencies and scaffolded Expo Router + Tamagui layout, placeholder tab screens, TS path aliases, Zustand stores, and theme files.
- ✅ ESLint now runs clean with typed rules enabled (added `tsconfig.eslint.json` pointer + downgraded `@typescript-eslint/*` to v7.x for compatibility with `eslint-config-universe`).
- ✅ Tamagui theme now carries custom palettes/tokens and shared primitives (SurfaceCard, SectionHeader, Primary/Subtle buttons) powering Library/Playing/Settings UI mocks.
- ✅ Library + Playing tabs hydrate from mocked Zustand stores to showcase cards, progress, queue states, and CTA scaffolding.
- ✅ Expo Router stack now includes modal placeholders for Baidu OAuth and cache controls, linked from the Settings tab for navigation smoke-tests.
- ✅ Added AsyncStorage-based storage service so Library + Player stores hydrate from/persist to disk with seeded mock data.
- ✅ Integrated `react-native-track-player` end-to-end: background service registered, player store hydrates & syncs queue/state with Track Player, and Playing tab reflects buffering/playback state from the native engine.
- ✅ Added Baidu auth store/service backed by AsyncStorage; Settings tab + modal now reflect real auth state and can simulate OAuth login/logout for downstream wiring.
- ✅ Cache controls modal now connected to an AsyncStorage-backed cache store for TTL tweaks and cache-clear actions (stubbed metrics today, ready for real filesystem wiring).

## Next Steps
1. Replace the simulated Baidu OAuth flow with the real expo-auth-session integration + keychain storage.
2. Wire the cache store to real filesystem metrics (expo-file-system + Track Player cache) so TTL and clear buttons flush actual data.
3. Begin modeling Baidu/Library APIs so AsyncStorage mocks can transition to SQLite/WatermelonDB without breaking the RN screens.

## Open Questions / Risks
- Do we stay on Expo Managed workflow long term or eject for deeper background audio control?
- Which database layer (WatermelonDB vs SQLite wrappers) best matches GRDB parity requirements?
- Should RN live side-by-side in this repo permanently or spin out once stable?

## Session Log
| Date       | Notes |
|------------|-------|
| 2025-11-12 | Initialized Expo TS app (`react-native-app/`), documented goals + pending decisions. |
| 2025-11-13 | Repaired ESLint setup (typed parser config + plugin downgrade), refreshed Tamagui theme/primitives, mocked Library + Playing stores/UI, scaffolded Baidu/cache modals, added AsyncStorage-backed persistence, and wired the new stores into `react-native-track-player` with background service + buffering-aware UI. |
| 2025-11-13 | Upgraded RN toolchain + nav deps to the newest releases (`react-native@0.82.1`, React 19.2, `@react-navigation/*`, gesture-handler/screens/reanimated/safe-area/svg) to unblock npm install. `npx react-native run-ios --version` currently hangs in this environment; CLI bin works when invoked via Xcode/Metro, so follow up locally if a version printout is required. |

## Related Files
- `local/react-native-migration-plan.md`
- `react-native-app/`


## React-Native Repo Location
1. /Users/senaca/projects/happy-bear-app
