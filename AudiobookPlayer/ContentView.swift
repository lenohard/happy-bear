import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label(NSLocalizedString("library_tab", comment: "Tab for library"), systemImage: "books.vertical")
                }

            PlayingView()
                .tabItem {
                    Label(NSLocalizedString("playing_tab", comment: "Tab for now playing"), systemImage: "play.circle")
                }

            SourcesView()
                .tabItem {
                    Label(NSLocalizedString("sources_tab", comment: "Tab for sources"), systemImage: "externaldrive.badge.icloud")
                }
        }
    }
}

struct PlayingView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var missingAuthAlert = false

    private var currentPlayback: PlaybackSnapshot? {
        guard
            let collection = audioPlayer.activeCollection,
            let track = audioPlayer.currentTrack
        else {
            return nil
        }

        let state = collection.playbackState(for: track.id)
        return PlaybackSnapshot(collection: collection, track: track, state: state, isLive: true)
    }

    private var fallbackPlayback: PlaybackSnapshot? {
        if let currentPlayback {
            return currentPlayback
        }

        for collection in library.collections {
            if let track = collection.resumeTrack() {
                let state = collection.playbackState(for: track.id)
                return PlaybackSnapshot(collection: collection, track: track, state: state, isLive: false)
            }
        }

        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = fallbackPlayback {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            primaryCard(for: snapshot)

                            if !historyEntries(excluding: snapshot).isEmpty {
                                listeningHistorySection(entries: historyEntries(excluding: snapshot))
                            }
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 20)
                    }
                } else {
                    EmptyPlayingView()
                }
            }
            .navigationTitle(NSLocalizedString("playing_title", comment: "Playing tab title"))
        }
        .alert(NSLocalizedString("connect_baidu_first", comment: "Alert title"), isPresented: $missingAuthAlert) {
            Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("connect_baidu_before_stream", comment: "Alert message to sign in before streaming"))
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            syncPlaybackState()
        }
        .onChange(of: audioPlayer.currentTime) { _ in
            syncPlaybackState()
        }
    }

    @ViewBuilder
    private func primaryCard(for snapshot: PlaybackSnapshot) -> some View {
        if snapshot.isLive {
            livePlaybackCard(snapshot: snapshot)
        } else {
            resumeCard(snapshot: snapshot)
        }
    }

    @ViewBuilder
    private func livePlaybackCard(snapshot: PlaybackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.collection.title)
                    .font(.title3)
                    .bold()
                    .lineLimit(2)

                Text(snapshot.track.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            liveTimeline()

            controlButtons()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func resumeCard(snapshot: PlaybackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("resume_listening", comment: "Resume listening label"))
                    .font(.headline)

                Text(snapshot.collection.title)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(2)

                Text(snapshot.track.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            savedProgressView(state: snapshot.state)

            resumeButton(collection: snapshot.collection, track: snapshot.track)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2))
        )
    }

    @ViewBuilder
    private func savedProgressView(state: TrackPlaybackState?) -> some View {
        if let state {
            if let duration = state.duration, duration > 0 {
                let clamped = min(state.position, duration)
                ProgressView(value: clamped, total: duration)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(clamped.formattedTimestamp) / \(duration.formattedTimestamp)")
                    Spacer()
                    Text(percentString(position: clamped, duration: duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(String(format: NSLocalizedString("last_position", comment: "Last position label"), state.position.formattedTimestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(NSLocalizedString("no_listening_progress", comment: "No listening progress message"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func liveTimeline() -> some View {
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

    @ViewBuilder
    private func controlButtons() -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Button {
                    audioPlayer.skipBackward(by: 15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }

                Button {
                    audioPlayer.playPreviousTrack()
                } label: {
                    Image(systemName: "backward.end.alt")
                        .font(.title3)
                }
                .disabled(!hasPreviousTrack)

                Button {
                    audioPlayer.togglePlayback()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }

                Button {
                    audioPlayer.playNextTrack()
                } label: {
                    Image(systemName: "forward.end.alt")
                        .font(.title3)
                }
                .disabled(!hasNextTrack)

                Button {
                    audioPlayer.skipForward(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

            if let collection = audioPlayer.activeCollection {
                NavigationLink(destination: CollectionDetailView(collectionID: collection.id)) {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text(NSLocalizedString("open_collection", comment: "Open collection button"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var hasPreviousTrack: Bool {
        guard
            let collection = audioPlayer.activeCollection,
            let currentTrack = audioPlayer.currentTrack
        else {
            return false
        }

        let tracks = collection.tracksSortedByFilename
        guard let index = tracks.firstIndex(where: { $0.id == currentTrack.id }) else {
            return false
        }

        return index > tracks.startIndex
    }

    private var hasNextTrack: Bool {
        guard
            let collection = audioPlayer.activeCollection,
            let currentTrack = audioPlayer.currentTrack
        else {
            return false
        }

        let tracks = collection.tracksSortedByFilename
        guard let index = tracks.firstIndex(where: { $0.id == currentTrack.id }) else {
            return false
        }

        let nextIndex = tracks.index(after: index)
        return tracks.indices.contains(nextIndex)
    }

    private func resumeButton(collection: AudiobookCollection, track: AudiobookTrack) -> some View {
        Button {
            resumePlayback(collection: collection, track: track)
        } label: {
            Label(NSLocalizedString("play_last_position", comment: "Play from last position button"), systemImage: "play.circle")
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let clamped = max(0, min(position / duration, 1))
        let percent = Int(round(clamped * 100))
        return "\(percent)%"
    }

    private func resumePlayback(collection: AudiobookCollection, track: AudiobookTrack) {
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

    private func syncPlaybackState() {
        guard
            let collection = audioPlayer.activeCollection,
            let track = audioPlayer.currentTrack
        else { return }

        library.recordPlaybackProgress(
            collectionID: collection.id,
            trackID: track.id,
            position: audioPlayer.currentTime,
            duration: audioPlayer.duration
        )
    }

    private func listeningHistorySection(entries: [ListeningHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("listening_history", comment: "Listening history section title"))
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(entries) { entry in
                    Button {
                        resumePlayback(collection: entry.collection, track: entry.track)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.collection.title)
                                    .font(.subheadline)
                                    .bold()
                                    .lineLimit(1)

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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var listeningHistory: [ListeningHistoryEntry] {
        let activeCollectionID = audioPlayer.activeCollection?.id
        let activeTrackID = audioPlayer.currentTrack?.id

        return library.collections
            .flatMap { collection in
                collection.playbackStates.compactMap { trackID, state in
                    guard
                        let track = collection.tracks.first(where: { $0.id == trackID })
                    else { return nil }

                    return ListeningHistoryEntry(
                        id: trackID,
                        collection: collection,
                        track: track,
                        state: state,
                        isActive: collection.id == activeCollectionID && trackID == activeTrackID
                    )
                }
            }
            .sorted { $0.state.updatedAt > $1.state.updatedAt }
            .prefix(5)
            .map { $0 }
    }

    private func historyEntries(excluding snapshot: PlaybackSnapshot) -> [ListeningHistoryEntry] {
        listeningHistory.filter { entry in
            entry.collection.id != snapshot.collection.id || entry.track.id != snapshot.track.id
        }
    }
}

private struct PlaybackSnapshot {
    let collection: AudiobookCollection
    let track: AudiobookTrack
    let state: TrackPlaybackState?
    let isLive: Bool
}

private struct ListeningHistoryEntry: Identifiable {
    let id: UUID
    let collection: AudiobookCollection
    let track: AudiobookTrack
    let state: TrackPlaybackState
    let isActive: Bool

    init(id: UUID, collection: AudiobookCollection, track: AudiobookTrack, state: TrackPlaybackState, isActive: Bool) {
        self.id = id
        self.collection = collection
        self.track = track
        self.state = state
        self.isActive = isActive
    }
}

private struct EmptyPlayingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(NSLocalizedString("nothing_playing_yet", comment: "Empty playing view title"))
                .font(.title3)
                .bold()

            Text(NSLocalizedString("nothing_playing_message", comment: "Empty playing view message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(LibraryStore())
        .environmentObject(BaiduAuthViewModel())
}
