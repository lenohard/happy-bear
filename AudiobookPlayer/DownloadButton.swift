import SwiftUI

struct DownloadButton: View {
    let track: AudiobookTrack
    let collection: AudiobookCollection

    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        let status = audioPlayer.cacheStatus(for: track)

        VStack {
            if let status = status {
                switch status.state {
                case .fullyCached:
                    // Downloaded state - show as disabled button but allow delete
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(NSLocalizedString("download_button_downloaded", comment: "Downloaded button label"))
                                .font(.subheadline)
                        }
                    }
                    .disabled(true)
                    .confirmationDialog(
                        NSLocalizedString("delete_cache_title", comment: "Delete cached track confirmation"),
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("delete_cache_confirm", comment: "Delete cached track button"), role: .destructive) {
                            audioPlayer.removeCache(for: track)
                        }
                        Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
                    } message: {
                        Text(String(format: NSLocalizedString("delete_cache_message", comment: "Delete cached track message"), track.displayName))
                    }

                case .partiallyCached, .notCached:
                    // Download state
                    Button {
                        audioPlayer.cacheTrackIfNeeded(track)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text(NSLocalizedString("download_button_download", comment: "Download button label"))
                                .font(.subheadline)
                        }
                    }
                    .buttonStyle(.bordered)

                case .local:
                    // Local file - no download button needed
                    EmptyView()
                }
            } else {
                // No status available, treat as not cached
                Button {
                    audioPlayer.cacheTrackIfNeeded(track)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text(NSLocalizedString("download_button_download", comment: "Download button label"))
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    DownloadButton(
        track: AudiobookTrack(
            id: UUID(),
            displayName: "Chapter 1",
            filename: "chapter1.mp3",
            location: .baidu(fsId: 123456, path: "/audiobooks/test/chapter1.mp3"),
            fileSize: 52428800,
            duration: 3600,
            trackNumber: 1,
            checksum: nil,
            metadata: [:]
        ),
        collection: AudiobookCollection(
            id: UUID(),
            title: "Test Collection",
            author: nil,
            description: nil,
            coverAsset: CollectionCover(kind: .solid(colorHex: "#5B8DEF"), dominantColorHex: nil),
            createdAt: Date(),
            updatedAt: Date(),
            source: .ephemeralBaidu(path: "/test-collection"),
            tracks: [],
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: []
        )
    )
    .environmentObject(AudioPlayerViewModel())
}
