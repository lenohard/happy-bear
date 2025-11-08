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

private enum FavoriteTracksPreviewData {
    static func sampleEntries() -> [LibraryStore.FavoriteTrackEntry] {
        makeCollections().flatMap { collection in
            collection.tracks
                .filter(\.isFavorite)
                .map { LibraryStore.FavoriteTrackEntry(collection: collection, track: $0) }
        }
    }

    @MainActor
    static func makePreviewEnvironment() -> (library: LibraryStore, audioPlayer: AudioPlayerViewModel, authViewModel: BaiduAuthViewModel) {
        let library = LibraryStore(autoLoadOnInit: false, syncEngine: nil)
        let collections = makeCollections()
        collections.forEach { library.save($0) }

        let audioPlayer = AudioPlayerViewModel()
        if let firstCollection = library.collections.first {
            audioPlayer.prepareCollection(firstCollection)
        }

        let authViewModel = BaiduAuthViewModel(
            serviceFactory: { .failure(.missingConfiguration) },
            tokenStore: PreviewBaiduTokenStore()
        )

        return (library, audioPlayer, authViewModel)
    }

    private static func makeCollections() -> [AudiobookCollection] {
        var fiction = AudiobookCollection.makeEmptyDraft(
            for: .local(directoryBookmark: Data("fiction-preview".utf8)),
            title: "Fiction Classics"
        )
        fiction.author = "Curated Library"
        var sciFi = makeTrack(
            title: "Beyond the Stars",
            number: 1,
            minutes: 42,
            favoriteHoursAgo: 2
        )
        var noir = makeTrack(
            title: "Midnight Detective",
            number: 2,
            minutes: 38,
            favoriteHoursAgo: 6
        )
        noir.isFavorite = true
        fiction.tracks = [sciFi, noir]
        fiction.lastPlayedTrackId = sciFi.id
        fiction.playbackStates = [
            sciFi.id: TrackPlaybackState(position: 120, duration: 2_400, updatedAt: Date())
        ]

        var mindfulness = AudiobookCollection.makeEmptyDraft(
            for: .local(directoryBookmark: Data("mindfulness-preview".utf8)),
            title: "Mindful Evenings"
        )
        mindfulness.author = "Serenity Voices"
        let calm = makeTrack(
            title: "Gentle Arrival",
            number: 1,
            minutes: 25,
            favoriteHoursAgo: 30
        )
        mindfulness.tracks = [calm]

        return [fiction, mindfulness]
    }

    private static func makeTrack(
        title: String,
        number: Int,
        minutes: Double,
        favoriteHoursAgo: Double
    ) -> AudiobookTrack {
        AudiobookTrack(
            id: UUID(),
            displayName: title,
            filename: "\(number)-\(title.replacingOccurrences(of: " ", with: ""))",
            location: .local(urlBookmark: Data("track-\(title)".utf8)),
            fileSize: 28_000_000,
            duration: minutes * 60,
            trackNumber: number,
            checksum: nil,
            metadata: [:],
            isFavorite: true,
            favoritedAt: Date().addingTimeInterval(-(favoriteHoursAgo * 3_600))
        )
    }
}

private final class PreviewBaiduTokenStore: BaiduOAuthTokenStore {
    private var storedToken: BaiduOAuthToken?

    func loadToken() throws -> BaiduOAuthToken? {
        storedToken
    }

    func saveToken(_ token: BaiduOAuthToken) throws {
        storedToken = token
    }

    func clearToken() throws {
        storedToken = nil
    }
}

@MainActor
private struct FavoriteTracksPreviewHarness: View {
    @StateObject private var library: LibraryStore
    @StateObject private var audioPlayer: AudioPlayerViewModel
    @StateObject private var authViewModel: BaiduAuthViewModel

    init() {
        let environment = FavoriteTracksPreviewData.makePreviewEnvironment()
        _library = StateObject(wrappedValue: environment.library)
        _audioPlayer = StateObject(wrappedValue: environment.audioPlayer)
        _authViewModel = StateObject(wrappedValue: environment.authViewModel)
    }

    var body: some View {
        NavigationStack {
            FavoriteTracksView()
        }
        .environmentObject(library)
        .environmentObject(audioPlayer)
        .environmentObject(authViewModel)
    }
}

#Preview("Favorite Tracks List") {
    FavoriteTracksPreviewHarness()
}

#Preview("Favorite Track Row") {
    let entries = FavoriteTracksPreviewData.sampleEntries()

    return VStack(alignment: .leading, spacing: 16) {
        if let primary = entries.first {
            FavoriteTrackRow(
                entry: primary,
                isActive: true,
                onPlay: {},
                onToggleFavorite: {}
            )
        }

        if entries.count > 1 {
            FavoriteTrackRow(
                entry: entries[1],
                isActive: false,
                onPlay: {},
                onToggleFavorite: {}
            )
        }
    }
    .padding()
    .previewLayout(.sizeThatFits)
}
