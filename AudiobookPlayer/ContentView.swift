import SwiftUI

@MainActor
final class TabSelectionManager: ObservableObject {
    @Published var selectedTab: Tab = .library
    
    enum Tab: Int, CaseIterable {
        case library = 0
        case playing = 1
        case sources = 2
        case ai = 3
        case tts = 4
        
        var title: String {
            switch self {
            case .library:
                return NSLocalizedString("library_tab", comment: "Tab for library")
            case .playing:
                return NSLocalizedString("playing_tab", comment: "Tab for now playing")
            case .sources:
                return NSLocalizedString("sources_tab", comment: "Tab for sources")
            case .ai:
                return NSLocalizedString("ai_tab", comment: "AI tab")
            case .tts:
                return NSLocalizedString("tts_tab", comment: "TTS tab")
            }
        }

        var icon: String {
            switch self {
            case .library:
                return "books.vertical"
            case .playing:
                return "play.circle"
            case .sources:
                return "externaldrive.badge.icloud"
            case .ai:
                return "brain"
            case .tts:
                return "waveform"
            }
        }
    }
    
    func switchToPlayingTab() {
        selectedTab = .playing
    }
}

struct ContentView: View {
    @StateObject private var tabSelection = TabSelectionManager()
    
    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            LibraryView()
                .tabItem {
                    Label(NSLocalizedString("library_tab", comment: "Tab for library"), systemImage: "books.vertical")
                }
                .tag(TabSelectionManager.Tab.library)

            PlayingView()
                .tabItem {
                    Label(NSLocalizedString("playing_tab", comment: "Tab for now playing"), systemImage: "play.circle")
                }
                .tag(TabSelectionManager.Tab.playing)

            SourcesView()
                .tabItem {
                    Label(NSLocalizedString("sources_tab", comment: "Tab for sources"), systemImage: "externaldrive.badge.icloud")
                }
                .tag(TabSelectionManager.Tab.sources)

            AITabView()
                .tabItem {
                    Label(NSLocalizedString("ai_tab", comment: "AI tab"), systemImage: "brain")
                }
                .tag(TabSelectionManager.Tab.ai)

            TTSTabView()
                .tabItem {
                    Label(NSLocalizedString("tts_tab", comment: "TTS tab"), systemImage: "waveform")
                }
                .tag(TabSelectionManager.Tab.tts)
        }
        .environmentObject(tabSelection)
    }
}

struct PlayingView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var missingAuthAlert = false
    @State private var showingCacheManagement = false
    @State private var showingEphemeralSave = false

    private var currentPlayback: PlaybackSnapshot? {
        guard let currentTrack = audioPlayer.currentTrack else {
            return nil
        }

        if let activeCollection = audioPlayer.activeCollection {
            if activeCollection.isEphemeral {
                let transientState = TrackPlaybackState(
                    position: audioPlayer.currentTime,
                    duration: audioPlayer.duration > 0 ? audioPlayer.duration : nil,
                    updatedAt: Date()
                )
                return PlaybackSnapshot(collection: activeCollection, track: currentTrack, state: transientState, isLive: true)
            }

            if let collection = library.collections.first(where: { $0.id == activeCollection.id }),
               let track = collection.tracks.first(where: { $0.id == currentTrack.id }) {
                let state = collection.playbackState(for: track.id)
                return PlaybackSnapshot(collection: collection, track: track, state: state, isLive: true)
            }
        }

        // Defensive fallback: if track not in activeCollection, search all collections
        // This handles the case where activeCollection got out of sync with actual playback
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id == currentTrack.id }) {
                let state = collection.playbackState(for: track.id)
                return PlaybackSnapshot(collection: collection, track: track, state: state, isLive: true)
            }
        }

        return nil
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

                            if !snapshot.collection.isEphemeral,
                               !historyEntries(excluding: snapshot).isEmpty {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCacheManagement = true
                } label: {
                    Image(systemName: "internaldrive")
                }
                .accessibilityLabel("Open Cache Settings")
            }
        }
        .alert(NSLocalizedString("connect_baidu_first", comment: "Alert title"), isPresented: $missingAuthAlert) {
            Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("connect_baidu_before_stream", comment: "Alert message to sign in before streaming"))
        }
        .sheet(isPresented: $showingCacheManagement) {
            CacheManagementView()
                .environmentObject(audioPlayer)
        }
        .sheet(isPresented: $showingEphemeralSave) {
            if let folderPath = audioPlayer.ephemeralContext?.sourceDirectory {
                NavigationStack {
                    CreateCollectionView(
                        folderPath: folderPath,
                        tokenProvider: { authViewModel.token },
                        onComplete: { _ in
                            showingEphemeralSave = false
                        }
                    )
                }
            } else {
                EmptyView()
            }
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

            controlButtons(collection: snapshot.collection, track: snapshot.track)
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
            HStack(alignment: .top) {
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
                
                Spacer()
                
                FavoriteToggleButton(isFavorite: snapshot.track.isFavorite) {
                    library.toggleFavorite(for: snapshot.track.id, in: snapshot.collection.id)
                }
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
    private func controlButtons(collection: AudiobookCollection, track: AudiobookTrack) -> some View {
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

            compactActionRow(collection: collection, track: track)
        }
    }

    @ViewBuilder
    private func compactActionRow(collection: AudiobookCollection, track: AudiobookTrack) -> some View {
        HStack(spacing: 12) {
            if collection.isEphemeral {
                Label(NSLocalizedString("ephemeral_streaming_badge", comment: "Ephemeral streaming badge"), systemImage: "bolt.horizontal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if authViewModel.token == nil {
                        missingAuthAlert = true
                    } else {
                        showingEphemeralSave = true
                    }
                } label: {
                    Label(NSLocalizedString("ephemeral_save_button", comment: "Ephemeral save button"), systemImage: "tray.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            } else {
                NavigationLink(destination: CollectionDetailView(collectionID: collection.id)) {
                    HStack(spacing: 6) {
                        Image(systemName: "books.vertical")
                        Text(NSLocalizedString("open_collection", comment: "Open collection button"))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    library.toggleFavorite(for: track.id, in: collection.id)
                } label: {
                    Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(track.isFavorite ? .pink : .gray)
                }
                .buttonStyle(.plain)
            }

            if case .baidu = track.location {
                let status = audioPlayer.cacheStatus(for: track)
                Button {
                    showingCacheManagement = true
                } label: {
                    HStack(spacing: 4) {
                        Text(statusTitle(for: status))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
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

    private func percentageString(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return "\(percent)%"
    }

    private func cacheAmountText(for status: AudioPlayerViewModel.CacheStatusSnapshot) -> String {
        let cached = bytesString(status.cachedBytes)
        let total = status.totalBytes.map(bytesString) ?? "--"
        return "\(cached) of \(total) cached"
    }

    private func statusTitle(for status: AudioPlayerViewModel.CacheStatusSnapshot?) -> String {
        guard let status else {
            return "Streaming"
        }

        switch status.state {
        case .fullyCached:
            return NSLocalizedString("fully_cached", comment: "Cache status when fully cached")
        case .partiallyCached:
            return NSLocalizedString("partially_cached", comment: "Cache status when partially cached")
        case .notCached:
            return NSLocalizedString("not_cached", comment: "Cache status when not cached")
        case .local:
            return NSLocalizedString("local_file", comment: "Cache status for local file")
        }
    }

    private func bytesString(_ value: Int) -> String {
        guard value > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
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
            !collection.isEphemeral,
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

                                HStack(spacing: 4) {
                                    Text(entry.track.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    
                                    if entry.track.isFavorite {
                                        Image(systemName: "heart.fill")
                                            .foregroundStyle(.pink)
                                            .font(.caption)
                                            .accessibilityHidden(true)
                                    }
                                }
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

        // For each collection, find the most recent track
        var historyByCollection: [ListeningHistoryEntry] = []

        for collection in library.collections {
            // Find the most recently updated track in this collection
            var mostRecentEntry: (trackID: UUID, track: AudiobookTrack, state: TrackPlaybackState)? = nil
            var mostRecentDate: Date? = nil

            for (trackID, state) in collection.playbackStates {
                guard let track = collection.tracks.first(where: { $0.id == trackID }) else { continue }

                if mostRecentDate == nil || state.updatedAt > mostRecentDate! {
                    mostRecentDate = state.updatedAt
                    mostRecentEntry = (trackID: trackID, track: track, state: state)
                }
            }

            if let entry = mostRecentEntry {
                historyByCollection.append(
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

        // Sort by most recent and take top 5
        return historyByCollection
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

private struct CacheManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @State private var retentionDays: Int = 0
    @State private var showClearAllConfirmation = false
    @State private var showClearTrackConfirmation = false

    private var currentTrack: AudiobookTrack? {
        audioPlayer.currentTrack
    }

    private var currentTrackStatus: AudioPlayerViewModel.CacheStatusSnapshot? {
        guard let track = currentTrack else { return nil }
        return audioPlayer.cacheStatus(for: track)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("cache_storage_section", comment: "Storage section title")) {
                    HStack {
                        Text(NSLocalizedString("cache_total_size", comment: "Total cache size label"))
                        Spacer()
                        Text(audioPlayer.formattedCacheSize())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("cache_folder", comment: "Cache folder label"))
                        Text(audioPlayer.cacheDirectoryPath())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Stepper(value: $retentionDays, in: 1...30, step: 1) {
                        Text(String(format: NSLocalizedString("cache_retention_days", comment: "Cache retention days format"), retentionDays, retentionDays == 1 ? NSLocalizedString("cache_day", comment: "Day") : NSLocalizedString("cache_days", comment: "Days")))
                    }
                    .onChange(of: retentionDays) { newValue in
                        audioPlayer.updateCacheRetention(days: newValue)
                    }

                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        Label(NSLocalizedString("cache_clear_all", comment: "Clear all cached audio"), systemImage: "trash.slash")
                    }
                }

                if let track = currentTrack {
                    Section(NSLocalizedString("cache_current_track_section", comment: "Current track section title")) {
                        Text(track.displayName)
                            .font(.headline)

                        if let status = currentTrackStatus {
                            // Compact status row: status + size + clear button in one line
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(statusTitle(for: status))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(cacheAmountText(for: status))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if status.state != .notCached {
                                    Button(role: .destructive) {
                                        showClearTrackConfirmation = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                }
                            }

                            if status.state != .fullyCached {
                                Button {
                                    audioPlayer.cacheTrackIfNeeded(track)
                                } label: {
                                    Label(NSLocalizedString("cache_download_offline", comment: "Download for offline listening"), systemImage: "arrow.down.circle")
                                }
                            }
                        } else {
                            Text(NSLocalizedString("cache_streaming_directly", comment: "Streaming directly from Baidu Netdisk"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("cache_settings_title", comment: "Cache settings title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("done_button", comment: "Done button")) { dismiss() }
                }
            }
            .confirmationDialog(NSLocalizedString("cache_clear_all_title", comment: "Clear cached audio confirmation title"), isPresented: $showClearAllConfirmation, titleVisibility: .visible) {
                Button(NSLocalizedString("cache_clear_all_confirm", comment: "Delete all cached audio button"), role: .destructive) {
                    audioPlayer.clearAllCache()
                }
                Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("cache_clear_all_message", comment: "Clear all cached audio confirmation message"))
            }
            .confirmationDialog(NSLocalizedString("cache_clear_track_title", comment: "Remove cached copy of this track confirmation title"), isPresented: $showClearTrackConfirmation, titleVisibility: .visible) {
                Button(NSLocalizedString("cache_clear_track_confirm", comment: "Remove track cache button"), role: .destructive) {
                    if let track = currentTrack {
                        audioPlayer.removeCache(for: track)
                    }
                }
                Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("cache_clear_track_message", comment: "Remove track cache confirmation message"))
            }
            .onAppear {
                retentionDays = audioPlayer.cacheRetentionDays()
            }
        }
    }

    private func cacheAmountText(for status: AudioPlayerViewModel.CacheStatusSnapshot) -> String {
        let cached = bytesString(status.cachedBytes)
        let total = status.totalBytes.map(bytesString) ?? "--"
        return "\(cached) of \(total) cached"
    }

    private func statusTitle(for status: AudioPlayerViewModel.CacheStatusSnapshot) -> String {
        switch status.state {
        case .fullyCached:
            return NSLocalizedString("fully_cached", comment: "Cache status when fully cached")
        case .partiallyCached:
            return NSLocalizedString("partially_cached", comment: "Cache status when partially cached")
        case .notCached:
            return NSLocalizedString("not_cached", comment: "Cache status when not cached")
        case .local:
            return NSLocalizedString("local_file", comment: "Cache status for local file")
        }
    }

    private func bytesString(_ value: Int) -> String {
        guard value > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(LibraryStore())
        .environmentObject(BaiduAuthViewModel())
}

private struct CompactGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }
}
