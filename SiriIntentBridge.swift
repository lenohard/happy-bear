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
