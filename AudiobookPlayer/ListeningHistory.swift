import Foundation

struct ListeningHistoryEntry: Identifiable {
    let id: UUID
    let collection: AudiobookCollection
    let track: AudiobookTrack
    let state: TrackPlaybackState
    let isActive: Bool
}

@MainActor
func buildListeningHistory(
    from library: LibraryStore,
    using audioPlayer: AudioPlayerViewModel,
    limit: Int? = nil
) -> [ListeningHistoryEntry] {
    let activeCollectionID = audioPlayer.activeCollection?.id
    let activeTrackID = audioPlayer.currentTrack?.id

    var entries: [ListeningHistoryEntry] = []

    for collection in library.collections {
        var mostRecentEntry: (trackID: UUID, track: AudiobookTrack, state: TrackPlaybackState)?
        var mostRecentDate: Date?

        for (trackID, state) in collection.playbackStates {
            guard let track = collection.tracks.first(where: { $0.id == trackID }) else {
                continue
            }

            if mostRecentDate == nil || state.updatedAt > mostRecentDate! {
                mostRecentDate = state.updatedAt
                mostRecentEntry = (trackID: trackID, track: track, state: state)
            }
        }

        if let entry = mostRecentEntry {
            entries.append(
                ListeningHistoryEntry(
                    id: entry.trackID,
                    collection: collection,
                    track: entry.track,
                    state: entry.state,
                    isActive: collection.id == activeCollectionID && entry.trackID == activeTrackID
                )
            )
        }
    }

    let sorted = entries.sorted { $0.state.updatedAt > $1.state.updatedAt }

    if let limit {
        return Array(sorted.prefix(limit))
    }

    return sorted
}
