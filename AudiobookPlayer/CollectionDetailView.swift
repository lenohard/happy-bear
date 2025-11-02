import SwiftUI

struct CollectionDetailView: View {
    let collectionID: UUID

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var searchText = ""
    @State private var missingAuthAlert = false

    private var collection: AudiobookCollection? {
        library.collections.first { $0.id == collectionID }
    }

    private var sortedTracks: [AudiobookTrack] {
        guard let collection else { return [] }
        return collection.tracks.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
    }

    private var filteredTracks: [AudiobookTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedTracks }

        return sortedTracks.filter { track in
            track.displayName.localizedCaseInsensitiveContains(query) ||
            track.filename.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if let collection {
                listContent(collection)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Collection Not Found")
                        .font(.headline)

                    Text("This audiobook collection could not be located in your library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .navigationTitle(collection?.title ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search tracks")
        .alert("Connect Baidu First", isPresented: $missingAuthAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Sign in on the Sources tab before streaming from Baidu Netdisk.")
        }
        .onAppear {
            if let collection {
                audioPlayer.prepareCollection(collection)
            }
        }
        .onChange(of: collection?.tracks ?? []) { _ in
            if let collection {
                audioPlayer.prepareCollection(collection)
            }
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            guard
                audioPlayer.activeCollection?.id == collectionID,
                let collection,
                let track = audioPlayer.currentTrack
            else { return }

            var updated = collection
            updated.lastPlayedTrackId = track.id
            updated.lastPlaybackPosition = audioPlayer.currentTime
            updated.updatedAt = Date()
            library.save(updated)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let collection {
                    Button {
                        playFirstTrack(in: collection)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    .disabled(sortedTracks.isEmpty)
                }
            }
        }
    }

    private func listContent(_ collection: AudiobookCollection) -> some View {
        List {
            summarySection(collection)
            nowPlayingSection()
            tracksSection(collection)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func summarySection(_ collection: AudiobookCollection) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(collection.title)
                    .font(.title3)
                    .bold()

                if let description = collection.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                let totalSize = collection.tracks.reduce(into: Int64(0)) { $0 += $1.fileSize }
                Text("\(collection.tracks.count) tracks • \(formatBytes(totalSize)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func nowPlayingSection() -> some View {
        if let track = audioPlayer.currentTrack, let collection = audioPlayer.activeCollection, collection.id == collectionID {
            Section("Now Playing") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(track.displayName)
                        .font(.headline)
                        .lineLimit(2)

                    if audioPlayer.duration > 0 {
                        PlaybackTimeline()
                    }

                    HStack(spacing: 24) {
                        Button {
                            audioPlayer.playPreviousTrack()
                        } label: {
                            Image(systemName: "backward.fill")
                        }
                        .disabled(!hasPreviousTrack(track))

                        Button {
                            audioPlayer.togglePlayback()
                        } label: {
                            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }

                        Button {
                            audioPlayer.playNextTrack()
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .disabled(!hasNextTrack(track))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func tracksSection(_ collection: AudiobookCollection) -> some View {
        Section("Tracks") {
            if filteredTracks.isEmpty {
                Text(searchText.isEmpty ? "No audio tracks found." : "No results for \"\(searchText)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        startPlayback(track, in: collection)
                    } label: {
                        TrackRow(
                            index: index,
                            track: track,
                            isActive: isCurrentTrack(track: track)
                        )
                    }
                }
            }
        }
    }

    private func playFirstTrack(in collection: AudiobookCollection) {
        guard let first = sortedTracks.first else { return }
        startPlayback(first, in: collection)
    }

    private func startPlayback(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let token = authViewModel.token else {
            missingAuthAlert = true
            return
        }

        audioPlayer.play(track: track, in: collection, token: token)

        var updated = collection
        updated.lastPlayedTrackId = track.id
        updated.lastPlaybackPosition = 0
        updated.updatedAt = Date()
        library.save(updated)
    }

    private func isCurrentTrack(track: AudiobookTrack) -> Bool {
        audioPlayer.currentTrack?.id == track.id && audioPlayer.activeCollection?.id == collectionID
    }

    private func hasNextTrack(_ track: AudiobookTrack) -> Bool {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return false
        }
        return sortedTracks.index(after: index) < sortedTracks.endIndex
    }

    private func hasPreviousTrack(_ track: AudiobookTrack) -> Bool {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return false
        }
        return index > sortedTracks.startIndex
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct TrackRow: View {
    let index: Int
    let track: AudiobookTrack
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayName)
                    .font(.body)
                    .lineLimit(2)

                Text(formatBytes(track.fileSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "play.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct PlaybackTimeline: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...(max(audioPlayer.duration, 1))
            )
            .tint(.accentColor)

            HStack {
                Text(audioPlayer.currentTime.formattedTimestamp)
                Spacer()
                Text(audioPlayer.duration.formattedTimestamp)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private extension Double {
    var formattedTimestamp: String {
        guard isFinite else { return "--:--" }

        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
