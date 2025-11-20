# Siri Control Implementation Task

**Status**: 🆕 In Planning  
**Objective**: Enable hands-free Siri/App Shortcut control to start playback of any audiobook collection from its saved position.  
**Target iOS Version**: iOS 17+ (App Intents framework)

---

## Snapshot
- App Intents surface a `Play Collection` voice shortcut that resolves user wording with fuzzy matching.  
- The shortcut launches playback via the shared audio service, preserving resume positions and showing lock-screen controls.  
- Localization (English + Simplified Chinese) must cover all user-facing Siri dialogs.  
- App Intents run out-of-process: data access uses lightweight shared caches or App Group storage, never UI-only singletons.

---

## User Story

As a cyclist/commuter, I want to say “Hey Siri, play [collection name] in Audiobook Player” and have playback resume immediately without touching the screen.

---

## Architecture Overview

### Core Components
1. **AppEntity** – `AudiobookCollectionEntity`: wraps `AudiobookCollection` metadata for Siri.  
2. **EntityQuery** – `AudiobookCollectionQuery`: resolves spoken names to collections.  
3. **AppIntent** – `PlayCollectionIntent`: triggers playback using the audio service.  
4. **AppShortcutsProvider** – `AudiobookShortcuts`: publishes phrases to Siri/Shortcuts.  
5. **Intent Bridge** – Lightweight service (`IntentPlaybackController`) that exposes playback APIs to intents while sharing data with the main app (App Group / shared cache).

### Data & Execution Flow
```
Voice Phrase → Siri parses “Play Fantasy Audiobooks”
        ↓
PlayCollectionIntent invoked in App Intents extension process
        ↓
AudiobookCollectionQuery.entities(matching:) performs fuzzy search
        ↓
IntentPlaybackController loads collection metadata from shared store
        ↓
Audio service resumes saved track (via AudioPlayerViewModel shared bridge)
        ↓
Now Playing updates; lock screen + remote commands activated
```

---

## How Siri Identifies Your App Intent

### Two-Layer Identification System

When user says "Play Fantasy Audiobooks", Siri identifies which app to invoke through:

**Layer 1: Phrase Registration (System Level)**
```
Voice Input: "Play Fantasy Audiobooks"
    ↓
Siri searches registered AppShortcut phrases in system database
    ↓
Finds match: "Play \(.collection) in Audiobook Player"
    ↓
System knows this phrase belongs to Audiobook Player
    ↓
Audiobook Player's PlayCollectionIntent is invoked
```

**Layer 2: Explicit App Name in Phrase (Strongest Signal)**
- Including "Audiobook Player" in the phrase is the most reliable way to disambiguate
- Example: "Play \(.collection) **in Audiobook Player**" vs generic "Play \(.collection)"
- If user says the app name, Siri has zero ambiguity even if other music apps register similar phrases

### Implementation Details

The `AppShortcutsProvider` mechanism works as follows:

1. **Registration**: When app installs/updates, iOS scans all `@AppShortcutsProvider` structs in your app
2. **System Database**: Each phrase from your `appShortcuts` array is registered to your app's bundle ID
3. **Siri Matching**: When user speaks, Siri matches against registered phrases and routes to the owning app
4. **Shortcut App Discovery**: Users can find your intent in Shortcuts app by searching "Play Collection" - system shows it's from Audiobook Player

### Why This Works for Mixed Language

- **Device Language Setting**: Siri checks device language and presents matching phrases to user:
  - Device set to Chinese → Siri offers Chinese phrases
  - Device set to English → Siri offers English phrases
- **No Extra Configuration Needed**: One AppShortcut array handles both languages automatically
- **User Flexibility**: User can speak their preferred language regardless of collection name language

### Verification Steps for App Identification

After implementing, verify Siri recognizes your app:

1. **In Shortcuts App**:
   - Open Shortcuts
   - Create new shortcut
   - Search "Play Collection"
   - Should see: "Play Collection - Audiobook Player" (with your app icon)

2. **Via Spotlight**:
   - Pull down Spotlight
   - Type collection name
   - Should show: "Play in Audiobook Player" option

3. **Via Siri Voice**:
   - "Hey Siri, play Fantasy Audiobooks in Audiobook Player"
   - Siri should confirm which app before executing
   - Device language setting affects which language Siri uses for confirmation

---

## Key Constraints & Risks
- **Out-of-process execution**: Intents cannot touch UI-bound singletons. Persist required library data (IDs, titles, resume state) in an App Group JSON cache before registering Siri. Validate `LibraryManager` already writes such cache, or add it.
- **Entitlements**: Enable “App Intents” capability plus App Group (for shared storage) in both the main app and intent target. Update `Info.plist` with `IntentsSupported` if needed.
- **Device testing**: Siri voice invocation and lock-screen validation require a physical device; the simulator only tests the Shortcuts preview UI.
- **Localization parity**: Every Siri string must have EN + zh-Hans entries; missing keys surface as raw identifiers.
- **Network resilience**: Playback may require Baidu token; handle expired tokens by prompting user to refresh when next opening app.

---

## Implementation Plan

### Phase 1 – App Intent Scaffolding

**Task 1.1 – `AudiobookCollectionEntity.swift`**  
File: `AudiobookPlayer/AppIntents/AudiobookCollectionEntity.swift`
- Declare `@AppEntity` conformer with `id`, `title`, optional `detail` (author/description).  
- Reference `typeDisplayRepresentation` using localized strings.  
- Wire `defaultQuery = AudiobookCollectionQuery()`.

Localization keys introduced: `siri_collection_entity_type`, `siri_collection_entity_type_plural`.

**Task 1.2 – `AudiobookCollectionQuery.swift`**  
File: `AudiobookPlayer/AppIntents/AudiobookCollectionQuery.swift`
- Implement `EntityQuery` functions: identifiers lookup, suggestions (recently played + favorites), fuzzy matching on `title` and alternate keywords.  
- Enforce limit (return <=10 suggestions).  
- Surface errors via localized `IntentError` messages.

Localization keys: `siri_collection_not_found`, `siri_collection_disambiguation`.

**Task 1.3 – `PlayCollectionIntent.swift`**  
File: `AudiobookPlayer/AppIntents/PlayCollectionIntent.swift`
- Define `@Parameter(title: String(localized: "siri_collection_param_title")) var collection`.  
- In `perform()`, call bridge `IntentPlaybackController.shared.playCollection(id:)` and return `Result.dialog(String(localized: "siri_intent_success_dialog", substitution: ...))`.  
- Map expected errors (no tracks, network, auth) to `IntentResult.failure(with:localized:)`.

Localization keys: `siri_intent_title`, `siri_intent_description`, `siri_intent_success_dialog`, `siri_no_tracks_error`, `siri_network_error`.

**Task 1.4 – `AudiobookShortcuts.swift`**
File: `AudiobookPlayer/AppIntents/AudiobookShortcuts.swift`
- Implement `AppShortcutsProvider` with **mixed English & Chinese phrases** for natural multi-language support.
- Provide localized `shortTitle`, `shortDescription`, and `systemImageName = "play.circle.fill"`.

**Mixed Language Phrase Design**:
```swift
phrases: [
    // English phrases - include App name to avoid ambiguity
    "Play \(.collection) in Audiobook Player",
    "Start \(.collection) audiobook",
    "Play my \(.collection)",
    "Resume \(.collection)",
    "Continue \(.collection)",

    // Chinese phrases - can be standalone or include App name
    "播放 \(.collection)",                      // Minimal (system context identifies app)
    "开始播放 \(.collection)",
    "播放我的 \(.collection)",
    "继续播放 \(.collection)",
    "播放 Audiobook Player 中的 \(.collection)",  // With App name for clarity
]
```

**Why Mixed Language Works**:
1. **Siri auto-detects device language**: Chinese users get Chinese phrases, English users get English phrases
2. **Collection names are often mixed**: e.g., "Fantasy 奇幻", "科幻 Sci-Fi", so mixing languages naturally handles this
3. **One AppShortcut = all languages**: No need to register separate intents

**Key Design Principle – Siri Intent Disambiguation**:
Siri identifies this is your app through **two mechanisms**:
1. **Explicit App Name in Phrase** (strongest): "... in Audiobook Player" → Siri immediately knows which app to invoke
2. **AppShortcutsProvider Registration** (implicit context): System registers all `AudiobookShortcuts` phrases as belonging to your app; Siri uses app context to resolve ambiguity

**Recommendation**: Include "Audiobook Player" in at least the main English phrase; Chinese phrases can be more flexible since spoken context typically makes the intent clear.

Localization keys: `siri_shortcut_title`, `siri_shortcut_subtitle`, `siri_shortcut_continue_phrase`.

**Task 1.5 – Register Provider**  
File: `AudiobookPlayer/AudiobookPlayerApp.swift`
- Import AppIntents.  
- Add `.appShortcutsProvider(AudiobookShortcuts.self)` inside `@main` app body.  
- Ensure initialization occurs once; no extra UI state is created.

**Task 1.6 – Configure Intents Target & Entitlements**
- Add an App Intents extension target (if absent) or enable capability on main target.  
- Update `AudiobookPlayer.entitlements` with `AppIntents = YES` and shared App Group identifier (e.g. `group.com.senaca.audiobookplayer`).  
- In `Info.plist`, set `IntentsSupported` to include `PlayCollectionIntent` if we expose via Siri Suggestions.

### Phase 2 – Playback Bridge

**Task 2.1 – Intent Playback Controller**  
File: `AudiobookPlayer/AppIntents/IntentPlaybackController.swift` (NEW)
- Non-UI singleton that interacts with shared storage + audio engine.  
- Loads `AudiobookCollection` snapshot (JSON) via `LibraryCache.shared` residing in App Group.  
- Calls into `AudioPlayerViewModel.shared` on main actor by dispatching a background notification (e.g. `NotificationCenter` + app delegate) or by leveraging `WidgetCenter.reloadAllTimelines()` style bridging if the app is foregrounded.  
- When app not running, queue the request in shared defaults so the app resumes playback when launched; respond to Siri with success after persisting.

**Task 2.2 – Audio Service API**  
File: `AudiobookPlayer/AudioPlayerViewModel.swift`
- Add `func handleIntentRequest(_ request: IntentPlaybackRequest) async throws` that validates tokens, ensures playlist ready, and returns status.  
- Guard against duplicate singletons; confirm existing `static let shared` is the same instance used in SwiftUI views (if not, refactor views to consume `AudioPlayerViewModel.shared`).

**Task 2.3 – Library Snapshotting**  
File: `AudiobookPlayer/LibraryManager.swift`
- Persist minimal collection metadata (id, title, resumeTrackId, resumePosition, cached flag) to App Group container whenever library mutates.  
- Provide read API for `AudiobookCollectionQuery` so Siri can operate without launching the full app.

### Phase 3 – Localization

**Task 3.1 – Update `Localizable.xcstrings`**
- Add the 12 keys listed below with EN + zh-Hans values.  
- Regenerate `.strings` files only after verifying manual edits.

**Task 3.2 – Regenerate `.strings` Files (if desired)**
- Run `python3 scripts/generate_strings.py` to sync `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.  
- If automation overkill, manually patch both files (<=12 entries).

**Task 3.3 – Add to Xcode Resources**
- Confirm `en.lproj` & `zh-Hans.lproj` exist in project (Build Phases ▸ Copy Bundle Resources).  
- Avoid pbxproj scripting; add via Xcode UI.

### Phase 4 – Testing & Validation

**Task 4.1 – Build Verification**  
```
xcodebuild -project AudiobookPlayer.xcodeproj \
  -scheme AudiobookPlayer \
  -destination 'generic/platform=iOS Simulator' \
  build
```
- Ensure App Intents target compiles, no missing entitlement warnings.

**Task 4.2 – Device Testing (Required)**
1. Deploy to iPhone/iPad running iOS 17+.  
2. In Shortcuts app, confirm “Play Collection” intent surfaces with localized copy.  
3. Invoke Siri via hardware button: “Play Fantasy Audiobooks in Audiobook Player.”  
4. Validate playback resumes saved position, lock screen media controls respond.  
5. Offline scenario: disable network, ensure cached tracks play; otherwise Siri returns localized network error.

**Task 4.3 – Edge Validation**
- Multiple collections with similar names ⇒ confirm disambiguation dialog uses localized message.  
- Non-existent collection ⇒ Siri reads `siri_collection_not_found`.  
- Token expired ⇒ user receives actionable prompt when opening app (documented in future task).

### Phase 5 – Polish & Handoff
- Review localization formatting (double braces, punctuation).  
- Document Siri setup in `local/docs/siri-collection-playback.md` (screenshots optional).  
- Update `PROD.md` progress + mark completion criteria.  
- Prepare demo video / instructions for user testing.

---

## Localization Summary

**Total Keys**: 12

| Key | English | Chinese (Simplified) |
|-----|---------|----------------------|
| `siri_collection_entity_type` | Audiobook Collection | 有声书集合 |
| `siri_collection_entity_type_plural` | Audiobook Collections | 有声书集合 |
| `siri_collection_param_title` | Collection | 集合 |
| `siri_intent_title` | Play Collection | 播放集合 |
| `siri_intent_description` | Start playback of a saved audiobook collection. | 开始播放已保存的有声书集合。 |
| `siri_intent_success_dialog` | Starting {{collection}}. | 正在播放{{collection}}。 |
| `siri_collection_not_found` | I couldn’t find that collection. | 我找不到对应的集合。 |
| `siri_collection_disambiguation` | Which collection did you mean? | 你想播放哪个集合？ |
| `siri_no_tracks_error` | This collection has no playable audio. | 该集合暂无可播放的音频。 |
| `siri_network_error` | Unable to access the collection. Check your internet connection. | 无法访问该集合，请检查网络连接。 |
| `siri_shortcut_title` | Play Collection | 播放集合 |
| `siri_shortcut_subtitle` | Resume an audiobook from where you left off. | 从上次停止处继续播放有声书。 |

*(Optional additional phrases such as `siri_shortcut_continue_phrase` can be added later if needed; keep total count aligned.)*

---

## Dependencies & Requirements
- iOS 17 or later (App Intents).  
- App Group identifier shared between app and intents extension.  
- `LibraryManager` must maintain lightweight cache accessible from intents.  
- `AudioPlayerViewModel` or equivalent playback service exposed via intent bridge.  
- Existing Baidu OAuth token retrieval must tolerate background access (Keychain access group configured).

---

## Success Criteria
- Siri/Shortcuts surfaces localized “Play Collection” intent with icon.  
- Spoken phrases resolve to correct collection within two disambiguation steps.  
- Playback starts (or queues) within one second after Siri confirmation when app in foreground; if app is backgrounded, playback begins automatically when app activates.  
- Resume position honored; fallback to first track if no history.  
- Lock screen shows correct artwork, metadata, and responds to transport controls.  
- Local and cloud collections both work (network error localized).  
- No hardcoded strings; localization QA passes.  
- No regressions in existing playback features (background audio, quick-play buttons).

---

## Next Steps
1. Confirm shared data strategy (App Group cache) with user.  
2. Create App Intents source files (Phase 1).  
3. Implement intent playback bridge + library snapshotting (Phase 2).  
4. Localize and regenerate `.strings` files (Phase 3).  
5. Build + device-test Siri flows (Phase 4).  
6. Update docs/PROD.md and prepare demo (Phase 5).

---

## References
- `local/docs/siri-collection-playback.md` – user flow & screenshots.  
- Apple App Intents documentation: https://developer.apple.com/documentation/appintents  
- EntityQuery guide: https://developer.apple.com/documentation/appintents/entityquery  
- AppShortcutsProvider guide: https://developer.apple.com/documentation/appintents/appshortcutsprovider

---

## Progress Tracking

**Created**: 2025-11-05
**Status**: 🆕 Phases 1-3 Complete - Bridge Infrastructure Built
**Last Updated**: 2025-11-05

### Session: 2025-11-05 - Implementation Complete

#### Phase 1 - App Intent Scaffolding ✅
- [x] `AudiobookCollectionEntity.swift` - wraps collection metadata with localization support
- [x] `AudiobookCollectionQuery.swift` - resolves spoken names to collections via fuzzy search
- [x] `PlayCollectionIntent.swift` - triggers playback via IntentPlaybackController
- [x] `AudiobookShortcuts.swift` - registers mixed English/Chinese voice phrases with Siri

#### Phase 2 - Playback Bridge ✅
- [x] `AudiobookCollectionSummary.swift` - lightweight model for App Group sharing
- [x] `LibrarySnapshotStore.swift` - actor-based store for shared library access
- [x] `IntentPlaybackController.swift` - bridges intent requests to playback system
- [x] `AudioPlayerViewModel` updates - added static shared instance + intent observer setup
- [x] Build verification - `xcodebuild` completed successfully

#### Phase 3 - Localization ✅
- [x] Added 13 Siri localization keys to `generate_strings.py`:
  - siri_collection_entity_type, siri_collection_entity_type_plural
  - siri_collection_param_title
  - siri_intent_title, siri_intent_description
  - siri_intent_success_dialog
  - siri_collection_not_found, siri_collection_disambiguation
  - siri_no_tracks_error, siri_network_error
  - siri_shortcut_title, siri_shortcut_subtitle
  - siri_playback_unavailable (+ plurals)
- [x] Regenerated `Localizable.xcstrings` (87 total strings)
- [x] Both EN and zh-Hans translations complete

### Remaining Tasks

#### Phase 3.5 - App Group Setup (PENDING)
- [ ] Configure App Group identifier in both main app and any intent extension target
- [ ] Update `AudiobookPlayer.entitlements` with shared container capability
- [ ] Enable "App Intents" capability in Xcode

#### Phase 4 - Device Testing (PENDING)
- [ ] Test Siri voice invocation on physical device (iOS 17+)
- [ ] Verify fuzzy matching for collection names
- [ ] Test offline scenarios (cached collections)
- [ ] Validate lock screen controls after Siri invocation

#### Phase 5 - Documentation Updates (PENDING)
- [ ] Document manual Xcode setup steps
- [ ] Capture device testing notes
- [ ] Update `PROD.md` final status

### Known Blocker
- **Free Apple Developer Account Limitation**: Cannot proceed to device testing without paid Apple Developer membership ($99/year)
  - Free/Team provisioning profiles do not support `com.apple.developer.appintents` entitlement
  - All implementation code saved in branch: `feature/siri-control-wip` (commit: `ba67470`)
  - **Action**: When account upgraded to paid, restore from WIP branch and proceed with Phases 3.5-5

### App Group Configuration
- **App Group identifier**: `group.com.senaca.audiobookplayer`
- **Data Access Strategy**: Intents run out-of-process; all data access via `LibrarySnapshotStore` (JSON in App Group)
- **IPC Strategy**: Notification-based IPC when app is in foreground; shared defaults for background queueing
