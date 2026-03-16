import Intents

/// Handles INPlayMediaIntent from Siri — runs in the Extension process,
/// even when the device is locked. Searches the shared collection catalog
/// to resolve spoken names, then writes a playback command to App Group
/// UserDefaults for the main app to pick up.
class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    private let suiteName = "group.com.wdh.happyBear"

    // MARK: - Resolve

    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // Extract search query from Siri's speech recognition
        let searchTerm: String? = intent.mediaSearch?.mediaName

        // If no search term, treat as "resume last played"
        guard let query = searchTerm, !query.isEmpty else {
            completion([.notRequired()])
            return
        }

        // Load the collection catalog from App Group shared storage
        let collections = loadSharedCollections()

        guard !collections.isEmpty else {
            // No catalog available — tell Siri we can't resolve
            completion([.unsupported()])
            return
        }

        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Fuzzy match: check if collection title contains query or vice versa
        let matches = collections.filter { col in
            let title = col.title.lowercased()
            return title.contains(lowered) || lowered.contains(title)
        }

        if matches.count == 1 {
            // Exact single match
            let item = INMediaItem(
                identifier: matches[0].id,
                title: matches[0].title,
                type: .audioBook,
                artwork: nil
            )
            completion([.success(with: item)])
        } else if matches.count > 1 {
            // Multiple matches — return disambiguation list
            let items = matches.map { col in
                INMediaItem(
                    identifier: col.id,
                    title: col.title,
                    type: .audioBook,
                    artwork: nil
                )
            }
            completion([.disambiguation(with: items)])
        } else {
            // No direct match — offer top 5 as disambiguation
            let topItems = collections.prefix(5).map { col in
                INMediaItem(
                    identifier: col.id,
                    title: col.title,
                    type: .audioBook,
                    artwork: nil
                )
            }
            if topItems.isEmpty {
                completion([.unsupported()])
            } else {
                completion([.disambiguation(with: Array(topItems))])
            }
        }
    }

    // MARK: - Handle

    func handle(intent: INPlayMediaIntent,
                completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        if let mediaItem = intent.mediaItems?.first,
           let identifier = mediaItem.identifier {
            // Play specific collection by ID (resolved from catalog)
            defaults.set(identifier, forKey: "siri_play_collection_id")
            defaults.removeObject(forKey: "siri_play_collection_search")
        } else if let mediaItem = intent.mediaItems?.first {
            // Fallback: search by title
            let title = mediaItem.title ?? ""
            defaults.removeObject(forKey: "siri_play_collection_id")
            defaults.set(title, forKey: "siri_play_collection_search")
        } else {
            // Resume last played
            defaults.set("__resume__", forKey: "siri_play_collection_id")
            defaults.removeObject(forKey: "siri_play_collection_search")
        }

        defaults.set(Date().timeIntervalSince1970, forKey: "siri_play_timestamp")
        defaults.synchronize()

        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }

    // MARK: - Shared Data

    private struct SharedCollection {
        let id: String
        let title: String
    }

    /// Load collection catalog from App Group UserDefaults (written by main app).
    private func loadSharedCollections() -> [SharedCollection] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: "siri_collection_catalog"),
              let list = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }

        return list.compactMap { dict in
            guard let id = dict["id"], let title = dict["title"] else { return nil }
            return SharedCollection(id: id, title: title)
        }
    }
}
