import Foundation
import Intents

/// Bridges SiriKit Media Intents (from the Intents Extension) to the main app.
/// The Extension writes commands to App Group UserDefaults; this class reads them.
@MainActor
final class SiriIntentBridge {
    static let shared = SiriIntentBridge()

    private let suiteName = "group.com.wdh.happyBear"
    private var lastProcessedTimestamp: TimeInterval = 0

    private init() {}

    /// Check for pending Siri playback commands. Call this on app foreground / scene active.
    func checkPendingSiriCommand() -> SiriPlaybackCommand? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }

        let timestamp = defaults.double(forKey: "siri_play_timestamp")
        guard timestamp > lastProcessedTimestamp else { return nil }

        // Don't process commands older than 30 seconds
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < 30 else {
            lastProcessedTimestamp = timestamp
            return nil
        }

        lastProcessedTimestamp = timestamp

        if let collectionId = defaults.string(forKey: "siri_play_collection_id") {
            if collectionId == "__resume__" {
                return .resumeLastPlayed
            } else if let uuid = UUID(uuidString: collectionId) {
                return .playCollection(id: uuid)
            }
        }

        if let search = defaults.string(forKey: "siri_play_collection_search"), !search.isEmpty {
            return .searchAndPlay(query: search)
        }

        return nil
    }

    /// Sync the collection catalog (id + title) to App Group UserDefaults
    /// so the SiriIntentsExtension can search during resolveMediaItems.
    /// Call this after library loads and whenever collections change.
    static func syncCollectionCatalog(_ collections: [AudiobookCollection]) {
        guard let defaults = UserDefaults(suiteName: "group.com.wdh.happyBear") else { return }
        let list: [[String: String]] = collections.map {
            ["id": $0.id.uuidString, "title": $0.title]
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: "siri_collection_catalog")
            defaults.synchronize()
            AppLog.debug("[Siri] Synced \(collections.count) collections to App Group catalog")
        }
    }

    /// Suggest all collections to Siri via INUpcomingMediaManager.
    /// This tells Siri what content is available for playback (not what the user already played).
    /// Call this after library finishes loading (e.g. on app launch).
    static func donateAllCollections(_ collections: [AudiobookCollection]) {
        let intents: [INPlayMediaIntent] = collections.map { collection in
            let mediaItem = INMediaItem(
                identifier: collection.id.uuidString,
                title: collection.title,
                type: .audioBook,
                artwork: nil
            )
            return INPlayMediaIntent(
                mediaItems: [mediaItem],
                mediaContainer: nil,
                playShuffled: nil,
                playbackRepeatMode: .unknown,
                resumePlayback: true,
                playbackQueueLocation: .unknown,
                playbackSpeed: nil,
                mediaSearch: nil
            )
        }
        INUpcomingMediaManager.shared.setSuggestedMediaIntents(NSOrderedSet(array: intents))
        AppLog.debug("[Siri] Suggested \(collections.count) collections via INUpcomingMediaManager")
    }

    /// Donate a playback intent so Siri learns the user's listening habits.
    static func donatePlayback(collectionTitle: String, collectionId: UUID) {
        let mediaItem = INMediaItem(
            identifier: collectionId.uuidString,
            title: collectionTitle,
            type: .audioBook,
            artwork: nil
        )

        let intent = INPlayMediaIntent(
            mediaItems: [mediaItem],
            mediaContainer: nil,
            playShuffled: nil,
            playbackRepeatMode: .unknown,
            resumePlayback: true,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error {
                AppLog.debug("[Siri] Donate failed: \(error.localizedDescription)")
            }
        }
    }
}

enum SiriPlaybackCommand {
    case resumeLastPlayed
    case playCollection(id: UUID)
    case searchAndPlay(query: String)
}
