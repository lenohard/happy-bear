# Task: Export & Import User Data

## Summary
- Provide a single "Export Everything" action that bundles the user library (collections, tracks, playback progress), transcription artifacts, personalization settings, and cached preferences into a portable archive.
- Allow importing one of these archives to fully restore an installation (new device, reinstall) while handling conflicts, schema migrations, and security-sensitive fields carefully.
- Deliver the archive as a `.zip` so we can include multiple JSON + SQLite payloads without relying on platform-specific containers.

## Scope
- **Included**: GRDB/SQLite databases, transcript files (text + timing only), playback snapshots/history, Settings/AppStorage toggles, cache TTL preference, Baidu folder shortcuts, favorites, AI/TTS configuration (but not raw API keys unless user opts in).
- **Excluded**: Cached audio blobs (too large, re-fetchable), JSON backups (deprecated), iCloud/CloudKit sync records (blocked by developer account), DRM-protected content.

## Functional Requirements
1. **Archive Composition**
   - `manifest.json`: schema version, export timestamp, app build, locale flags, optional notes, and which payloads are included.
   - `database/library.sqlite`: GRDB snapshot containing collections, tracks, playback states, tags, and transcript/job tables (no JSON fallback, no Soniox raw tokens/snippets anywhere).
   - `metadata/playback_state.json`: derived summary (helpful for human review + future delta support).
   - `metadata/settings.json`: cache TTL, UI prefs (AI tab expansion/search), default AI model, and other `UserDefaults` toggles.
   - `credentials/ai_gateway.json`, `credentials/soniox.json`, `credentials/baidu_oauth.json`: only written if the user opts in; otherwise we emit metadata-only stubs.
2. **Export UX**
   - Settings → Backup section with `Export Data` button, sheet summarizing what will be exported, credential checkbox, and success/failure toasts.
   - Writes `.zip` to Files app via `ShareLink`/`UIDocumentPicker` so user chooses destination (iCloud Drive, AirDrop, etc.).
3. **Import UX**
   - `Import Data` button opens document picker for `.happybear-export.zip` (exact UTI TBD).
   - Validate archive signature + metadata version before applying; show preview of contents and allow selective import (e.g., skip settings).
   - Map incoming schema version to current migrations (run GRDB migrator if needed, convert JSON if fallback).
4. **Conflict Handling (V1)**
   - Import is replace-only: when a backup is applied we archive the current `library.sqlite`, wipe it, and restore from the bundle.
   - We still log a preview of counts (collections, transcripts, settings) before the user confirms, but there is no partial merge UI in V1.
5. **Security**
   - Sensitive tokens remain excluded by default; if a user includes them, surface a warning that the zip is unencrypted and relies on their own handling.
   - Never log archive paths or token values; wipe temporary files after export/import completes; ensure temporary working directories are deleted once the share/export sheet dismisses.
6. **Reliability**
   - Background-friendly, resumable tasks using `Task` + progress indicators, with explicit error reporting and retry instructions.

## Non-Functional Requirements
- Schema versioning + forward compatibility so old exports import into newer builds.
- Localization for new strings (English + zh-Hans).
- Unit coverage for serialization/parsing utilities; manual QA checklist for full export/import verification.
- File sizes kept reasonable (<25 MB without cached audio) via compression and excluding redundant assets.

## Data Inventory & Owners
| Data | Current Source | Export Format | Notes |
|------|----------------|---------------|-------|
| Collections, tracks, playback, tags | `GRDBDatabaseManager` (library DB) | `database/library.sqlite` | Single vacuum snapshot so WAL/SHM not required |
| Playback progress + favorites summary | `LibraryStore.collections` | `metadata/playback_state.json` | Contains per-track position + `isFavorite` booleans for quick inspection |
| Transcripts + segments + job queue | `GRDBDatabaseManager` (same DB) | `database/library.sqlite` | No separate JSON; Soniox raw tokens are never saved |
| Settings & UI prefs | `UserDefaults` (`AudioCacheRetainedDays`, `ai_gateway_default_model`, `ai_tab_*`) | `metadata/settings.json` | Add new keys as features launch |
| AI/TTS credentials | `KeychainAIGatewayAPIKeyStore`, `KeychainSonioxAPIKeyStore` | `credentials/*.json` if opted-in | Plain JSON strings, strongly warn about storage |
| Baidu auth token | `KeychainBaiduOAuthTokenStore` | `credentials/baidu_oauth.json` if opted-in | JSON-encoded `BaiduOAuthToken`; expires per Baidu rules |

## Implementation Plan
1. **Design Backup Schema**: Define `ExportArchiveManifest` Swift structs, schema version constants, and JSON encoders/decoders with `Codable` + `ISO8601DateFormatter`.
2. **Service Layer**: Introduce `UserDataBackupManager` responsible for orchestrating GRDB snapshots, transcript export, settings collection, zipping/unzipping (via `AppleArchive` or `Compression` + `FileManager`).
3. **UI Surfaces**: Add a "Backup & Restore" section inside `SettingsTabView` with explanatory text, action buttons, and progress HUD (e.g., `ProgressView` + cancellable tasks).
4. **Import Flow**: Build a validator that inspects `metadata.json`, compares schema, prompts for merge/replace decisions, and applies changes via transactional GRDB writes (wrap in `DatabaseQueue.inDatabase`).
5. **Credential Handling**: Store export password (if provided) only in memory, derive key via `CryptoKit` (PBKDF2) and encrypt credential blob before zipping; document in UI.
6. **Testing & QA**: Write unit tests for manifest round-trips, simulate old-version imports, and create a manual checklist covering export/import on device + share sheet destinations.
7. **Documentation**: Update `AGENTS.md`, `local/PROD.md`, and release notes; include troubleshooting tips (e.g., failed unzip, missing permissions).

## Open Questions
- _None for V1_ (conflict handling is replace-only).

## Next Steps
- Confirm conflict-resolution UX placement.
- Execute implementation per plan below.

## Work Plan
1. **Data Inventory Pass**: catalog concrete code owners (LibraryStore, PlaybackSnapshotStore, TranscriptManager, AppStorage keys) and document exact serialization formats.
2. **Backup/Restore Service Layer**: add manifest structs, file layout helpers, zipping/unzipping, and transactional import routines (merge + replace logic, conflict detection hooks).
3. **Settings UI Integration**: add "Backup & Restore" section with export/import buttons, progress state, credential opt-in, warnings, and conflict presentation per chosen UX.

## Progress (2025-11-14)
- Implemented `UserDataBackupManager` with manifest v1, playback/settings snapshot writers, optional credential export, and replace-only import path. Added GRDB helpers for snapshotting/replacing the SQLite file plus transcript stats, and a `TranscriptionManager.reloadJobsAfterImport()` hook.
- Settings tab now includes a localized Backup & Restore section (credential toggle, export/import buttons, progress indicators, share sheet + file importer wiring).
- Outstanding: automated coverage for manifest encode/decode + import happy path, manual QA checklist, and release notes entry.

## Code Review Notes (2025-11-14)
- ✅ **Compile blocker fixed**: Removed unnecessary `await` when calling synchronous GRDB helpers, so `UserDataBackupManager` now builds cleanly.
- ✅ **Import durability**: `replaceDatabase(with:)` now snapshots the existing `library.sqlite` and restores it automatically if copying/initialization fails, preventing data loss.
- 🔄 **Credential restore atomicity**: still need orchestration so AI/Soniox/Baidu key imports roll back together on error.
- 🔄 **Manifest/context gaps**: reviewers asked for archive-level timestamps in playback snapshot (manifest already has `exportedAt`, but consider echoing inside snapshot), optional settings import, and integrity/HMAC checking.
- 🔄 **Security UX**: credential toggle shows a warning string, but we may want a modal confirmation and/or encrypted blobs for opt-in exports.

## Findings (2025-11-14 17:15)
- UI polish feedback: the Backup section inside `SettingsTabView` looks unfinished (plain list row, cramped spacing, buttons not full-width). Screenshot shows target style with rounded card, clearer hierarchy, and bilingual copy. Need to wrap content in a card, update typography, and align progress indicators with controls.
- Functional bug: tapping “Export” sometimes throws `SQLite error 6: database table is locked` while executing `PRAGMA wal_checkpoint(TRUNCATE)`. Root cause is we run the checkpoint inside `DatabaseQueue.write`, which opens a transaction. `wal_checkpoint(TRUNCATE)` cannot run inside an active transaction, so the call fails and surfaces the lock error.

## TODO (Session 2025-11-14 PM)
1. Rebuild the Backup card layout
   - Rounded rectangle background with grouped tint + subtle stroke
   - Descriptive text + credential toggle stacked with consistent spacing
   - Export/Import buttons full width, large control size, icons matching spec
   - Inline progress states + summaries positioned directly beneath their actions
2. Improve accessibility copy for credential warning + import destructive warning.
3. Move the checkpoint call to `writeWithoutTransaction` (no implicit transaction) so WAL truncation succeeds; keep the snapshot copy + manifest logic as-is.
4. Retest export/import to confirm: UI layout, share sheet, database snapshot, import reload.
5. Update this doc + PROD once the above lands; capture follow-up tasks (tests, encryption, optional settings import toggle).

## Implementation Notes (2025-11-14 17:28)
- **Backup card polish**: replaced the plain Section stack with a rounded card (`secondarySystemGroupedBackground` fill + subtle stroke). Buttons now stretch to the full width with `.controlSize(.large)` to match the mock, progress indicators sit directly under their respective actions, and state summaries use `fixedSize` so bilingual copy wraps predictably. The credential toggle uses `SwitchToggleStyle(tint:)` for better affordance, and the warning/description copy adopts `subheadline/caption` styles per spec.
- **Import panel polish**: destructive warning moved above the Import CTA with `footnote` styling; disabled state ties to `isImportingBackup`, and we reuse the new status view to present progress + completion summaries inline.
- **Checkpoint fix**: `GRDBDatabaseManager.exportDatabaseSnapshot` now calls `db.writeWithoutTransaction` before running `PRAGMA wal_checkpoint(TRUNCATE)`. This removes the implicit transaction that previously caused `SQLite error 6` and keeps the WAL clean prior to copying the snapshot.
- **Archive packaging**: added ZIPFoundation via Swift Package Manager and updated the helper to write/read a real `.zip`. We enumerate the working directory, add entries with deflate compression, and extract via the same library so Files/iCloud recognize the archive properly. Build succeeded with the new dependency (`xcodebuild -resolvePackageDependencies` + simulator build).
- **Post-import refresh**: after applying a backup we now refresh `AIGatewayViewModel` (key card state), `BaiduAuthViewModel` (token + status text), and `TranscriptionManager`'s Soniox API client immediately so the Settings/Baidu section and AI tab reflect restored credentials without requiring an app restart.
