# Siri Playback Registration Guide

## Goal
Allow people to invoke Siri with phrases like “Play my _Fantasy Audiobooks_ in Audiobook Player” and have the app immediately start playback of the matching collection.

## Prerequisites
- iOS 17+ target (App Intents with custom entities and Shortcuts integration are stable in iOS 17; assistant schemas in iOS 18 enhance natural language coverage).
- Existing collection model that uniquely identifies each collection and can resolve to a playable queue.
- Playback service capable of starting/resuming a collection via async method.

## Implementation Steps

1. **Adopt App Intents framework**
   - Add `import AppIntents` wherever you declare intents and entities.
   - Ensure the app target links App Intents (automatically handled by SwiftPM/Xcode for SwiftUI projects).

2. **Model the collection as an `AppEntity`**
   ```swift
   @AppEntity
   struct AudiobookCollectionEntity: Identifiable {
       static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audiobook Collection")
       static let defaultQuery = AudiobookCollectionQuery()

       let id: String

       @Property(title: "Collection")
       var title: String

       @Property(title: "Description")
       var subtitle: String?

       var displayRepresentation: DisplayRepresentation {
           DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title),
                                 subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) })
       }
   }
   ```
   - `id` should match your internal identifier (e.g. persisted collection ID or netdisk path).
   - Provide localized titles/subtitles to improve Siri’s confirmation dialog.

3. **Support voice disambiguation with an entity query**
   ```swift
   struct AudiobookCollectionQuery: EntityQuery {
       func entities(for identifiers: [AudiobookCollectionEntity.ID]) async throws -> [AudiobookCollectionEntity] {
           try await Library.shared.collections(for: identifiers).map(AudiobookCollectionEntity.init)
       }

       func suggestedEntities() async throws -> [AudiobookCollectionEntity] {
           try await Library.shared.frequentCollections().map(AudiobookCollectionEntity.init)
       }

       func entities(matching search: EntityQuerySearch<AudiobookCollectionEntity>) async throws -> [AudiobookCollectionEntity] {
           try await Library.shared.searchCollections(search.query).map(AudiobookCollectionEntity.init)
       }
   }
   ```
   - Provide at least `entities(for:)` and `suggestedEntities()` so Siri can resolve spoken names and show autocompletions in Shortcuts.

4. **Create the intent that plays a collection**
   ```swift
   struct PlayCollectionIntent: AppIntent {
       static let title: LocalizedStringResource = "play_collection_title"
       static let description = IntentDescription("Start playback of a saved audiobook collection.")

       @Parameter(title: "Collection")
       var collection: AudiobookCollectionEntity

       func perform() async throws -> some IntentResult & ProvidesDialog {
           try await PlaybackController.shared.play(collectionID: collection.id)
           return .result(dialog: IntentDialog("Starting \(collection.title)."))
       }
   }
   ```
   - Localize all displayed strings (title, description, dialog) to align with existing localization practices.
   - Use your playback controller to start the queue. Handle errors (e.g. missing files) with thrown `IntentError` values and user-facing dialog.

5. **Publish the intent via `AppShortcutsProvider`**
   ```swift
   struct AudiobookShortcuts: AppShortcutsProvider {
       static var appShortcuts: [AppShortcut] {
           AppShortcut(intent: PlayCollectionIntent(),
                       phrases: ["Play \(.collection) in Audiobook Player",
                                 "Start \(.collection) audiobook"],
                       shortTitle: "Play Collection",
                       systemImageName: "play.circle.fill")
       }
   }
   ```
   - Include multiple phrase templates. Siri automatically inflects names, but Assistant Schemas (iOS 18) will broaden understanding further.
   - Provide a `systemImageName` for Shortcuts UI consistency.

6. **Surface live collection context for Siri suggestions**
   - When a collection is on-screen, associate the entity with an `NSUserActivity` using `.userActivity(_:element:)`. This enables “Hey Siri, play this collection” while browsing.
   - Ensure the activity’s `appEntityIdentifier` matches the entity ID.

7. **Test and submit for review**
   - Build `Shortcuts` on a device, add the new shortcut, and trigger it via Siri, Spotlight, and App Shortcuts widget.
   - Validate offline/online scenarios. Siri requires a successful intent execution path even when the collection is cached locally.
   - Document the Siri command in App Store submission notes and marketing copy so reviewers understand the feature.

## Registration Checklist
- [ ] `PlayCollectionIntent` added to the App target.
- [ ] `AudiobookCollectionEntity` resolves collections and returns localized display data.
- [ ] Intent wired into playback controller with robust error handling.
- [ ] `AppShortcutsProvider` exposes sample phrases covering your branding.
- [ ] Localization strings updated in both `en.lproj` and `zh-Hans.lproj`.
- [ ] Manual testing through Siri, Shortcuts, Spotlight searches.
- [ ] QA log attached (device/OS/Siri phrases attempted) ready for App Review.

## Follow-Up Ideas
- Adopt assistant schemas once iOS 18 is your deployment target to let Siri infer audiobook playback intents without explicit shortcut phrases.
- Provide additional intents (pause, resume, next track) so Siri Shortcuts can build richer automations.
