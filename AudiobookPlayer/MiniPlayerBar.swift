import SwiftUI
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

/// Bottom mini-player bar shown above the tab bar on Library / Smart / Personal tabs.
/// Displays current track info, progress, and a play/pause button.
struct MiniPlayerBar: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var playbackClock: PlaybackClock
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var themeManager: ThemeManager

    // Local cached cover image for fast display.
    @State private var coverImage: UIImage?
    @State private var loadedCoverPath: String?

    var body: some View {
        if let track = audioPlayer.currentTrack,
           let collection = audioPlayer.activeCollection,
           tabSelection.selectedTab != .playing
        {
            miniPlayerContent(track: track, collection: collection)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func miniPlayerContent(
        track: AudiobookTrack,
        collection: AudiobookCollection
    ) -> some View {
        VStack(spacing: 0) {
            dividerLine
            HStack(spacing: 12) {
                Button {
                    tapBar()
                } label: {
                    HStack(spacing: 12) {
                        coverThumbnail(collection: collection)
                        trackInfo(track: track, collection: collection)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                playPauseButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 56)
            .background(.regularMaterial)
        }
        .onAppear { refreshCover(for: collection) }
        .onChange(of: collection.coverAsset) { refreshCover(for: collection) }
    }

    // MARK: - Subviews

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
    }

    private func coverThumbnail(collection: AudiobookCollection) -> some View {
        Group {
            switch collection.coverAsset.kind {
            case .solid(let colorHex):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hexString: colorHex))
                    .frame(width: 40, height: 40)
            case .image:
                if let img = coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    placeholderCover
                }
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    case .failure, .empty:
                        placeholderCover
                    @unknown default:
                        placeholderCover
                    }
                }
            }
        }
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.gray.opacity(0.25))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            )
    }

    private func trackInfo(track: AudiobookTrack, collection: AudiobookCollection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(collection.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            progressBarView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressBarView: some View {
        let progress = playbackClock.duration > 0
            ? min(max(playbackClock.currentTime / playbackClock.duration, 0), 1)
            : 0.0

        return ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(themeManager.colors.isFestive ? themeManager.colors.festiveRed : .accentColor)
            .scaleEffect(x: 1, y: 0.7, anchor: .center)
    }

    private var playPauseButton: some View {
        Button {
            hapticLight()
            audioPlayer.togglePlayback()
        } label: {
            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(themeManager.colors.isFestive
                    ? themeManager.colors.festiveRed : .accentColor)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func tapBar() {
        hapticLight()
        tabSelection.switchToPlayingTab()
    }

    private func refreshCover(for collection: AudiobookCollection) {
        guard case let .image(relativePath) = collection.coverAsset.kind else {
            loadedCoverPath = nil
            coverImage = nil
            return
        }
        loadedCoverPath = relativePath
        let cacheKey = relativePath
        if let cached = CollectionCoverArtView.thumbnailCache.object(forKey: cacheKey as NSString) {
            coverImage = cached
            return
        }
        // Background load — the thumbnail cache will be hit on next update.
        Task.detached(priority: .utility) {
            let url = CollectionCoverImageStore.fileURL(for: relativePath)
            guard let image = downsampleMiniPlayerCover(at: url) else { return }
            CollectionCoverArtView.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.loadedCoverPath == relativePath else { return }
                self.coverImage = image
            }
        }
    }
}

// MARK: - Helpers

/// Downsamples cover for mini-player thumbnail size (40 pt × scale).
private func downsampleMiniPlayerCover(at url: URL) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

    let maxPixelSize: CGFloat = 120  // 40 pt × 3× scale
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
    ] as CFDictionary

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return UIImage(cgImage: cgImage)
}
