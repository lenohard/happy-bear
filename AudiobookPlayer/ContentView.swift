import SwiftUI

@MainActor
final class TabSelectionManager: ObservableObject {
    @Published var selectedTab: Tab = .playing
    @Published var libraryNavigationTarget: UUID?

    enum Tab: Int, CaseIterable {
        case library = 0
        case playing = 1
        case ai = 2
        case tts = 3
        case settings = 4

        var title: String {
            switch self {
            case .library:
                return NSLocalizedString("library_tab", comment: "Tab for library")
            case .playing:
                return NSLocalizedString("playing_tab", comment: "Tab for now playing")
            case .ai:
                return NSLocalizedString("ai_tab", comment: "AI tab")
            case .tts:
                return NSLocalizedString("tts_tab", comment: "TTS tab")
            case .settings:
                return NSLocalizedString("settings_tab", comment: "Settings tab")
            }
        }

        var icon: String {
            switch self {
            case .library:
                return "books.vertical"
            case .playing:
                return "play.circle"
            case .ai:
                return "sparkles"
            case .tts:
                return "waveform"
            case .settings:
                return "gear"
            }
        }
    }
    
    func switchToPlayingTab() {
        selectedTab = .playing
    }
    
    func navigateToCollection(_ collectionID: UUID) {
        libraryNavigationTarget = collectionID
        selectedTab = .library
    }
}

struct ContentView: View {
    @StateObject private var tabSelection = TabSelectionManager()
    @StateObject private var bubbleViewModel = FloatingPlaybackBubbleViewModel()
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager

    var body: some View {
        GeometryReader { geometry in
            ZStack {
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

                    AITabView()
                        .tabItem {
                            Label(NSLocalizedString("ai_tab", comment: "AI tab"), systemImage: "sparkles")
                        }
                        .tag(TabSelectionManager.Tab.ai)

                    TTSTabView()
                        .tabItem {
                            Label(NSLocalizedString("tts_tab", comment: "TTS tab"), systemImage: "waveform")
                        }
                        .badge(transcriptionManager.activeJobs.count)
                        .tag(TabSelectionManager.Tab.tts)

                    SettingsTabView()
                        .tabItem {
                            Label(NSLocalizedString("settings_tab", comment: "Settings tab"), systemImage: "gear")
                        }
                        .tag(TabSelectionManager.Tab.settings)
                }
            }
            .overlay(alignment: .topLeading) {
                // Floating Playback Bubble
                FloatingPlaybackBubbleView(viewModel: bubbleViewModel)
            }
            .environmentObject(tabSelection)
            .onReceive(NotificationCenter.default.publisher(for: .resumePlaybackShortcut)) { _ in
                handleResumeShortcut()
            }
        }
    }

    private func handleResumeShortcut() {
        if let activeCollection = audioPlayer.activeCollection,
           let currentTrack = audioPlayer.currentTrack {
            playFromShortcut(collection: activeCollection, track: currentTrack)
        } else {
            for collection in library.collections {
                if let track = collection.resumeTrack() {
                    playFromShortcut(collection: collection, track: track)
                    break
                }
            }
        }

        tabSelection.selectedTab = .playing
    }

    private func playFromShortcut(collection: AudiobookCollection, track: AudiobookTrack) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }
    }
}

struct PlayingView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var transcriptionManager: TranscriptionManager

    @State private var missingAuthAlert = false
    @State private var showingEphemeralSave = false
    @State private var transcriptViewerTrack: AudiobookTrack?
    @State private var transcriptionSheetContext: TranscriptionSheetContext?
    @State private var transcriptStatus: TranscriptStatus = .unknown
    @State private var transcriptStatusTask: Task<Void, Never>?
    @State private var libraryLoaded = false
    @StateObject private var trackSummaryViewModel = TrackSummaryViewModel()

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
                if libraryLoaded, let snapshot = fallbackPlayback {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            primaryCard(for: snapshot)

                            if snapshot.isLive {
                                standaloneSummaryCard(for: snapshot)
                            }

                            if !historyEntries(excluding: snapshot).isEmpty {
                                listeningHistorySection(entries: historyEntries(excluding: snapshot))
                            }
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 20)
                    }
                } else if libraryLoaded {
                    EmptyPlayingView()
                } else {
                    // Show a loading state while library is loading
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
        .sheet(item: $transcriptionSheetContext) { context in
            TranscriptionSheet(
                track: context.track,
                collectionID: context.collectionID,
                collectionTitle: context.collectionTitle,
                collectionDescription: context.collectionDescription
            )
        }
        .sheet(item: $transcriptViewerTrack) { track in
            TranscriptViewerSheet(trackId: track.id.uuidString, trackName: track.displayName)
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            syncPlaybackState()
            refreshTranscriptStatus()
            let trackId = audioPlayer.currentTrack.map { $0.id.uuidString }
            trackSummaryViewModel.setTrackId(trackId)
        }
        .onChange(of: audioPlayer.currentTime) { _ in
            syncPlaybackState()
        }
        .onChange(of: library.isLoading) { isLoading in
            if !isLoading {
                libraryLoaded = true
            }
        }
        .onChange(of: aiGenerationManager.activeJobs) { jobs in
            trackSummaryViewModel.handleJobUpdates(
                activeJobs: jobs,
                recentJobs: aiGenerationManager.recentJobs
            )
        }
        .onChange(of: aiGenerationManager.recentJobs) { jobs in
            trackSummaryViewModel.handleJobUpdates(
                activeJobs: aiGenerationManager.activeJobs,
                recentJobs: jobs
            )
        }
        .task {
            let trackId = audioPlayer.currentTrack.map { $0.id.uuidString }
            trackSummaryViewModel.setTrackId(trackId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptDidFinalize)) { notification in
            guard let completedTrackId = notification.userInfo?["trackId"] as? String else { return }

            if audioPlayer.currentTrack?.id.uuidString == completedTrackId {
                refreshTranscriptStatus()
            }

            trackSummaryViewModel.handleTranscriptFinalized(trackId: completedTrackId)
        }
        .onAppear {
            refreshTranscriptStatus()
            // If library is already loaded, mark it as loaded
            if !library.isLoading {
                libraryLoaded = true
            }
        }
        .onDisappear {
            transcriptStatusTask?.cancel()
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
            HStack(alignment: .top) {
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

                Spacer()

                transcriptButton(for: snapshot.track, in: snapshot.collection)
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
    private func standaloneSummaryCard(for snapshot: PlaybackSnapshot) -> some View {
        TrackSummaryCard(
            track: snapshot.track,
            isTranscriptAvailable: transcriptStatusForTrack(snapshot.track) == .available,
            viewModel: trackSummaryViewModel,
            seekAndPlayAction: { time in seekAndPlay(to: time) }
        )
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
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

    private func playbackSpeedControls() -> some View {
        let label = formattedSpeed(audioPlayer.playbackRate)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("playback_speed_label", comment: "Playback speed label"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Text(label)
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )
                    .accessibilityLabel(String(format: NSLocalizedString("playback_speed_value", comment: "Playback speed accessibility label"), label))
            }

            Slider(
                value: Binding(
                    get: { audioPlayer.playbackRate },
                    set: { audioPlayer.updatePlaybackRate($0) }
                ),
                in: AudioPlayerViewModel.minPlaybackRate...AudioPlayerViewModel.maxPlaybackRate,
                step: 0.05
            )
            .tint(.accentColor)
            .accessibilityLabel(NSLocalizedString("playback_speed_label", comment: "Playback speed label"))
            .accessibilityValue(label)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AudioPlayerViewModel.presetPlaybackRates, id: \.self) { rate in
                        let isSelected = abs(rate - audioPlayer.playbackRate) < 0.01
                        Button {
                            audioPlayer.updatePlaybackRate(rate)
                        } label: {
                            Text(formattedSpeed(rate))
                                .font(.caption)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                                )
                                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func controlButtons(collection: AudiobookCollection, track: AudiobookTrack) -> some View {
        VStack(spacing: 16) {
            playbackSpeedControls()

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
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.plain)
                .font(.subheadline)
            } else {
                Button {
                    tabSelection.navigateToCollection(collection.id)
                } label: {
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
                DownloadButton(track: track, collection: collection)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func transcriptButton(for track: AudiobookTrack, in collection: AudiobookCollection) -> some View {
        switch transcriptStatusForTrack(track) {
        case .available:
            Button {
                transcriptViewerTrack = track
            } label: {
                Image(systemName: "text.alignleft")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle()
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("view_transcript", comment: "View transcript menu item"))
        case .unavailable:
            if canStartTranscription(in: collection) {
                Button {
                    presentTranscriptionSheet(for: track, in: collection)
                } label: {
                    Image(systemName: isTranscriptionInProgress(for: track) ? "waveform" : "waveform.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(isTranscriptionInProgress(for: track) ? 0.6 : 1))
                        )
                        .overlay {
                            if isTranscriptionInProgress(for: track) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("transcribe_track_title", comment: "Transcribe track title"))
                .disabled(isTranscriptionInProgress(for: track))
            }
        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.accentColor)
                .frame(width: 32, height: 32)
        case .unknown:
            EmptyView()
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

    private func seekAndPlay(to time: TimeInterval) {
        audioPlayer.seek(to: time)
        if !audioPlayer.isPlaying {
            audioPlayer.startPlaybackImmediately()
            audioPlayer.isPlaying = true
        }
    }

    private func presentTranscriptionSheet(for track: AudiobookTrack, in collection: AudiobookCollection) {
        transcriptionSheetContext = TranscriptionSheetContext(
            track: track,
            collectionID: collection.id,
            collectionTitle: collection.title,
            collectionDescription: collection.description
        )
    }

    private func percentString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let clamped = max(0, min(position / duration, 1))
        let percent = Int(round(clamped * 100))
        return "\(percent)%"
    }

    private func formattedSpeed(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "x"
    }

    private func percentageString(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
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

    private func refreshTranscriptStatus() {
        transcriptStatusTask?.cancel()

        guard
            let collection = audioPlayer.activeCollection,
            !collection.isEphemeral,
            let track = audioPlayer.currentTrack
        else {
            transcriptStatus = .unavailable
            return
        }

        transcriptStatus = .loading
        transcriptStatusTask = Task {
            do {
                let manager = GRDBDatabaseManager.shared
                try await manager.initializeDatabase()
                let hasTranscript = try await manager.hasCompletedTranscript(forTrackId: track.id.uuidString)
                await MainActor.run {
                    transcriptStatus = hasTranscript ? .available : .unavailable
                }
            } catch {
                await MainActor.run {
                    transcriptStatus = .unavailable
                }
            }
        }
    }

    private func transcriptStatusForTrack(_ track: AudiobookTrack) -> TranscriptStatus {
        guard let currentTrack = audioPlayer.currentTrack, currentTrack.id == track.id else {
            return .unavailable
        }
        return transcriptStatus
    }

    private func isTranscriptionInProgress(for track: AudiobookTrack) -> Bool {
        transcriptionManager.activeJobs.contains { job in
            job.trackId == track.id.uuidString && job.isRunning
        }
    }

    private func canStartTranscription(in collection: AudiobookCollection) -> Bool {
        guard !collection.isEphemeral else { return false }
        return library.canModifyCollection(collection.id)
    }
}

private enum TranscriptStatus {
    case unknown
    case loading
    case available
    case unavailable
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

private struct TranscriptionSheetContext: Identifiable {
    let track: AudiobookTrack
    let collectionID: UUID
    let collectionTitle: String
    let collectionDescription: String?

    var id: UUID { track.id }
}

#Preview {
    let library = LibraryStore(autoLoadOnInit: false)
    let player = AudioPlayerViewModel()
    
    // Create dummy data with fixed UUIDs for consistent DB operations in preview
    let dummyTrackId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let dummyCollectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    
    let dummyTrack = AudiobookTrack(
        id: dummyTrackId,
        displayName: "Chapter 1 - The Beginning",
        filename: "chapter1.mp3",
        location: .external(url: URL(string: "https://example.com/audio.mp3")!),
        fileSize: 1024 * 1024 * 10,
        duration: 300,
        trackNumber: 1,
        checksum: nil,
        metadata: [:],
        isFavorite: true
    )
    
    let dummyCollection = AudiobookCollection(
        id: dummyCollectionId,
        title: "The Great Adventure",
        author: "John Doe",
        description: "An epic journey through time and space.",
        coverAsset: CollectionCover(kind: .solid(colorHex: "#5B8DEF"), dominantColorHex: nil),
        createdAt: Date(),
        updatedAt: Date(),
        source: .external(description: "Preview Source"),
        tracks: [dummyTrack],
        lastPlayedTrackId: dummyTrack.id,
        playbackStates: [dummyTrack.id: TrackPlaybackState(position: 45, duration: 300, updatedAt: Date())],
        tags: ["Fiction", "Adventure"]
    )
    
    // Populate library
    library.save(dummyCollection)
    
    // Populate player
    player.loadCollection(dummyCollection)
    
    // Inject Dummy Transcript and Summary into DB
    Task {
        let dbManager = GRDBDatabaseManager.shared
        try? await dbManager.initializeDatabase()
        
        // 1. Insert Transcript
        try? await dbManager.saveTranscript(
            id: UUID().uuidString,
            trackId: dummyTrack.id.uuidString,
            collectionId: dummyCollection.id.uuidString,
            language: "en",
            fullText: "This is a dummy transcript text for preview purposes. It simulates a real transcript that would be generated by the AI.",
            jobStatus: "complete",
            jobId: "dummy-job"
        )
        
        // 2. Insert Summary
        let sections = [
            TrackSummarySection(
                trackSummaryId: dummyTrack.id.uuidString,
                orderIndex: 0,
                startTimeMs: 0,
                endTimeMs: 30000,
                title: "Introduction",
                summary: "The beginning of the chapter introduces the main character and the setting.",
                keywords: ["intro", "start"]
            ),
            TrackSummarySection(
                trackSummaryId: dummyTrack.id.uuidString,
                orderIndex: 1,
                startTimeMs: 30000,
                endTimeMs: 60000,
                title: "The Conflict",
                summary: "A sudden conflict arises that sets the plot in motion.",
                keywords: ["conflict", "plot"]
            )
        ]
        
        try? await dbManager.persistTrackSummaryResult(
            trackId: dummyTrack.id.uuidString,
            transcriptId: "dummy-transcript-id",
            language: "en",
            summaryTitle: "Chapter 1 Summary",
            summaryBody: "This is a generated summary for the chapter. It covers the introduction and the main conflict.",
            keywords: ["chapter", "summary", "adventure"],
            sections: sections,
            modelIdentifier: "gpt-4",
            jobId: "dummy-job-id"
        )
    }
    
    return ContentView()
        .environmentObject(player)
        .environmentObject(library)
        .environmentObject(BaiduAuthViewModel())
        .environmentObject(TranscriptionManager())
        .environmentObject(AIGatewayViewModel())
        .environmentObject(AIGenerationManager())
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
