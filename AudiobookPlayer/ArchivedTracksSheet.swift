import SwiftUI

/// Sheet displaying all archived tracks for a collection
struct ArchivedTracksSheet: View {
    let tracks: [AudiobookTrack]
    let collectionID: UUID
    
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if tracks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Archived Tracks")
                            .font(.headline)
                        Text("Archived tracks will appear here when you finish playing them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                HStack(spacing: 12) {
                                    // Track info
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.displayName)
                                            .font(.body)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                        
                                        if let duration = track.duration, duration > 0 {
                                            Text(formatDuration(duration))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        
                                        if let chapter = track.chapter, !chapter.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder")
                                                    .font(.caption2)
                                                Text(chapter)
                                                    .font(.caption2)
                                            }
                                            .foregroundStyle(.tertiary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    // Playback indicator
                                    if audioPlayer.currentTrack?.id == track.id {
                                        Image(systemName: audioPlayer.isPlaying ? "play.fill" : "pause.fill")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                    
                                    // Quick play button
                                    Button {
                                        playTrack(track)
                                    } label: {
                                        Image(systemName: "play.circle")
                                            .font(.title3)
                                            .foregroundStyle(.blue)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        library.unarchiveTrack(track, in: collectionID)
                                    } label: {
                                        Label(
                                            NSLocalizedString("unarchive_button", value: "Unarchive", comment: "Unarchive button"),
                                            systemImage: "tray.and.arrow.up.fill"
                                        )
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .leading) {
                                    Button(role: .destructive) {
                                        library.removeTrackFromCollection(collectionID: collectionID, trackID: track.id)
                                    } label: {
                                        Label(
                                            NSLocalizedString("delete_action", comment: "Delete action"),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: "archivebox.fill")
                                    .foregroundStyle(.orange)
                                Text(NSLocalizedString("archived_tracks_title", value: "Archived Tracks", comment: "Archived tracks title"))
                            }
                        } footer: {
                            Text(NSLocalizedString("archived_tracks_footer", value: "Swipe right to unarchive a track and return it to the main list.", comment: "Archived tracks footer"))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(format: NSLocalizedString("archived_tracks_count", value: "Archived (%d)", comment: "Archived tracks count"), tracks.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("close_button", comment: "Close button")) {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func playTrack(_ track: AudiobookTrack) {
        guard let collection = library.collections.first(where: { $0.id == collectionID }) else { return }
        
        if audioPlayer.activeCollection?.id == collection.id,
           audioPlayer.currentTrack?.id == track.id {
            audioPlayer.togglePlayback()
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
