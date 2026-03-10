import Intents

/// Handles INPlayMediaIntent from Siri — runs in the Extension process,
/// even when the device is locked. Writes a playback command to the shared
/// App Group UserDefaults, then the main app picks it up on activation.
class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    // Must match the App Group configured in both targets
    private let suiteName = "group.com.wdh.happyBear"

    // MARK: - Resolve

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // If Siri provides media items (user said a collection name), pass them through
        if let items = intent.mediaItems, !items.isEmpty {
            completion(items.map { .success(with: $0) })
        } else {
            // No specific item → will resume last played
            completion([INPlayMediaMediaItemResolutionResult.notRequired()])
        }
    }

    // MARK: - Handle

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        if let mediaItem = intent.mediaItems?.first,
           let identifier = mediaItem.identifier {
            // Play specific collection by ID
            defaults.set(identifier, forKey: "siri_play_collection_id")
            defaults.set(nil as String?, forKey: "siri_play_collection_search")
        } else if let mediaItem = intent.mediaItems?.first {
            // Search by title
            let title = mediaItem.title ?? ""
            defaults.set(nil as String?, forKey: "siri_play_collection_id")
            defaults.set(title, forKey: "siri_play_collection_search")
        } else {
            // Resume last played
            defaults.set("__resume__", forKey: "siri_play_collection_id")
            defaults.set(nil as String?, forKey: "siri_play_collection_search")
        }

        defaults.set(Date().timeIntervalSince1970, forKey: "siri_play_timestamp")
        defaults.synchronize()

        let response = INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
        completion(response)
    }
}
