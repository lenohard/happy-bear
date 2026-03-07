import Foundation
import SwiftUI

struct ListeningHistorySheet: View {
    let entries: [ListeningHistoryEntry]
    let onResume: (AudiobookCollection, AudiobookTrack) -> Void

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    onResume(entry.collection, entry.track)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.collection.title)
                                .font(.subheadline)
                                .bold()
                                .lineLimit(2)

                            Text(entry.track.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            if let duration = entry.state.duration, duration > 0 {
                                Text(percentString(position: entry.state.position, duration: duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.state.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(NSLocalizedString("listening_history", comment: "Listening history section title"))
        }
    }

    private func percentString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let clamped = max(0, min(position / duration, 1))
        let percent = Int(round(clamped * 100))
        return "\(percent)%"
    }

    @Environment(\.dismiss) private var dismiss
}

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
