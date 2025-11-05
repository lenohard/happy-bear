import SwiftUI

/// Dedicated favorites view showing all tracks the listener marked.
struct FavoriteTracksView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    
    @State private var missingAuthAlert = false
    
    private var entries: [LibraryStore.FavoriteTrackEntry] {
        library.favoriteTrackEntries()
    }
    
    var body: some View {
        List {
            if entries.isEmpty {
                emptyState
            } else {
                ForEach(entries) { entry in
                    FavoriteTrackRow(
                        entry: entry,
                        isActive: isTrackActive(entry),
                        onPlay: { play(entry: entry) },
                        onToggleFavorite: { toggleFavorite(entry) }
                    )
                }
                .animation(.default, value: entries)
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(NSLocalizedString("favorite_tracks_title", comment: "Favorite tracks view title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Text(NSLocalizedString("close_button", comment: "Close button"))
                }
            }
        }
        .alert(NSLocalizedString("connect_baidu_first", comment: "Alert title"), isPresented: $missingAuthAlert) {
            Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("connect_baidu_before_stream", comment: "Alert message to sign in before streaming"))
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text(NSLocalizedString("favorite_tracks_empty", comment: "Empty favorites message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func toggleFavorite(_ entry: LibraryStore.FavoriteTrackEntry) {
        library.toggleFavorite(for: entry.track.id, in: entry.collection.id)
    }
    
    private func play(entry: LibraryStore.FavoriteTrackEntry) {
        play(track: entry.track, in: entry.collection)
    }
    
    private func play(track: AudiobookTrack, in collection: AudiobookCollection) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                missingAuthAlert = true
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }
    }
    
    private func isTrackActive(_ entry: LibraryStore.FavoriteTrackEntry) -> Bool {
        audioPlayer.activeCollection?.id == entry.collection.id &&
        audioPlayer.currentTrack?.id == entry.track.id
    }
}

struct FavoriteTrackRow: View {
    let entry: LibraryStore.FavoriteTrackEntry
    let isActive: Bool
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    
    private var favoritedDateString: String? {
        guard let date = entry.track.favoritedAt else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.track.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    
                    if isActive {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                
                Text(entry.collection.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let favoritedDateString {
                    Text(favoritedDateString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            FavoriteToggleButton(isFavorite: entry.track.isFavorite) {
                onToggleFavorite()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .accessibilityElement(children: .combine)
    }
}
