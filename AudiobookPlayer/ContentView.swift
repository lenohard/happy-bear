import SwiftUI
import AVKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

@MainActor
final class TabSelectionManager: ObservableObject {
    @Published var selectedTab: Tab = .playing
    @Published var libraryNavigationTarget: UUID?

    enum Tab: Int, CaseIterable {
        case library = 0
        case playing = 1
        case smart = 2
        case personal = 3

        var title: String {
            switch self {
            case .library:
                return NSLocalizedString("library_tab", comment: "Tab for library")
            case .playing:
                return NSLocalizedString("playing_tab", comment: "Tab for now playing")
            case .smart:
                return "智能"
            case .personal:
                return "Personal"
            }
        }

        var icon: String {
            switch self {
            case .library:
                return "books.vertical"
            case .playing:
                return "play.circle"
            case .smart:
                return "sparkles"
            case .personal:
                return "person"
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
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager

    @State private var pendingResumeShortcutAfterLoad = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TabView(selection: tabSelectionBinding) {
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

                    SmartView()
                        .tabItem {
                            Label("智能", systemImage: "sparkles")
                        }
                        .badge(transcriptionManager.activeJobs.count + aiGenerationManager.activeJobs.count)
                        .tag(TabSelectionManager.Tab.smart)

                    PersonalView()
                        .tabItem {
                            Label("Personal", systemImage: "person")
                        }
                        .tag(TabSelectionManager.Tab.personal)
                }
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: .resumePlaybackShortcut)) { _ in
                if library.isLoading {
                    pendingResumeShortcutAfterLoad = true
                } else {
                    handleResumeShortcut()
                }
            }
            .onChange(of: library.isLoading) { isLoading in
                guard !isLoading, pendingResumeShortcutAfterLoad else { return }
                pendingResumeShortcutAfterLoad = false
                handleResumeShortcut()
            }
        }

    private func handleResumeShortcut() {
        if let activeCollection = audioPlayer.activeCollection,
           let currentTrack = audioPlayer.currentTrack {
            playFromShortcut(collection: activeCollection, track: currentTrack)
        } else if let recent = library.mostRecentPlayback() {
            playFromShortcut(collection: recent.collection, track: recent.track)
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

private extension ContentView {
    var tabSelectionBinding: Binding<TabSelectionManager.Tab> {
        Binding(
            get: { tabSelection.selectedTab },
            set: { tabSelection.selectedTab = $0 }
        )
    }
}

struct PlayingView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @AppStorage("autoGenerateTrackSummaries") private var autoGenerateTrackSummaries = true
    @AppStorage("autoSummaryEnforceDurationLimit") private var autoSummaryEnforceDurationLimit = true

    @State private var missingAuthAlert = false
    @State private var showingEphemeralSave = false
    @State private var transcriptViewerTrack: AudiobookTrack?
    @State private var transcriptionSheetContext: TranscriptionSheetContext?
    @State private var transcriptStatus: TranscriptStatus = .unknown
    @State private var transcriptStatusTask: Task<Void, Never>?
    @State private var libraryLoaded = false
    @StateObject private var trackSummaryViewModel = TrackSummaryViewModel()
    @State private var autoSummaryGuards: Set<String> = []
    @State private var showingVLCPlayer = false
    @State private var showingNativePlayer = false
    @State private var vlcPlayerURL: URL?
    @State private var vlcPlayerTitle: String = ""

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
                                
                                // Corrections card - separate section
                                if transcriptStatusForTrack(snapshot.track) == .available {
                                    TranscriptCorrectionsCard(track: snapshot.track)
                                }
                            }

                            if !snapshot.isLive && !historyEntries(excluding: snapshot).isEmpty {
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
        // Keep high-frequency playback ticks out of this view's invalidation path.
        .background(PlaybackProgressObserver(onTick: syncPlaybackState))
        .onChange(of: audioPlayer.currentTrack?.id) {
            syncPlaybackState()
            refreshTranscriptStatus()
            let trackId = audioPlayer.currentTrack.map { $0.id.uuidString }
            trackSummaryViewModel.setTrackId(trackId)
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
            let transcriptId = notification.userInfo?["transcriptId"] as? String

            if audioPlayer.currentTrack?.id.uuidString == completedTrackId {
                refreshTranscriptStatus()
            }

            trackSummaryViewModel.handleTranscriptFinalized(trackId: completedTrackId)

            Task { @MainActor in
                await autoGenerateSummaryIfNeeded(for: completedTrackId, transcriptId: transcriptId)
            }
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
        #if canImport(MobileVLCKit)
        .fullScreenCover(isPresented: $showingVLCPlayer) {
            if let url = vlcPlayerURL {
                let player = audioPlayer.getOrCreateVLCPlayer(url: url)
                VLCVideoPlayerSheet(
                    player: player,
                    title: vlcPlayerTitle,
                    onMinimize: {
                        showingVLCPlayer = false
                    },
                    onClose: {
                        audioPlayer.releaseVLCPlayer()
                        showingVLCPlayer = false
                    }
                )
            }
        }
        #endif
        .fullScreenCover(isPresented: $showingNativePlayer) {
            NativeVideoPlayerSheet(audioPlayer: audioPlayer)
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
                    
                    if snapshot.track.isVideoTrack {
                        Button {
                            openVideoPlayer(for: snapshot.track)
                        } label: {
                            Label("Show Video", systemImage: "film")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.1))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
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
                    audioPlayer.notifyFavoriteToggle(for: snapshot.track.id)
                }
            }

            savedProgressView(state: snapshot.state)

            resumeButton(collection: snapshot.collection, track: snapshot.track)

            Button {
                tabSelection.navigateToCollection(snapshot.collection.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                    Text(NSLocalizedString("open_collection", comment: "Open collection button"))
                }
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
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
            seekAndPlayAction: { time in seekAndPlay(to: time) },
            onRequestTranscription: {
                presentTranscriptionSheet(for: snapshot.track, in: snapshot.collection)
            }
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
        LiveTimelineView(seekAction: { audioPlayer.seek(to: $0) })
    }

    private func playbackSpeedControls() -> some View {
        PlaybackSpeedControl(
            playbackRate: Binding(
                get: { audioPlayer.playbackRate },
                set: { audioPlayer.updatePlaybackRate($0) }
            ),
            presets: AudioPlayerViewModel.presetPlaybackRates
        )
    }

    @ViewBuilder
    private func controlButtons(collection: AudiobookCollection, track: AudiobookTrack) -> some View {
        VStack(spacing: 16) {
            ZStack {
                // Sleep Timer aligned to the left
                HStack {
                    Menu {
                        Button {
                            audioPlayer.setSleepTimer(.endOfTrack)
                        } label: {
                            if audioPlayer.sleepTimerMode == .endOfTrack {
                                Label(NSLocalizedString("timer_end_of_episode", comment: "Timer end of episode"), systemImage: "checkmark")
                            } else {
                                Text(NSLocalizedString("timer_end_of_episode", comment: "Timer end of episode"))
                            }
                        }
                        
                        ForEach([60, 45, 30, 15, 10, 5], id: \.self) { minutes in
                            Button {
                                audioPlayer.setSleepTimer(.time(TimeInterval(minutes * 60)))
                            } label: {
                                let title = String(format: NSLocalizedString("timer_minutes", comment: "Timer duration"), minutes)
                                if case .time(let duration) = audioPlayer.sleepTimerMode, abs(duration - TimeInterval(minutes * 60)) < 1 {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                        
                        Button {
                            audioPlayer.setSleepTimer(.off)
                        } label: {
                            if audioPlayer.sleepTimerMode == .off {
                                Label(NSLocalizedString("timer_off", comment: "Timer off"), systemImage: "checkmark")
                            } else {
                                Text(NSLocalizedString("timer_off", comment: "Timer off"))
                            }
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 20))
                            if let remaining = audioPlayer.sleepTimerRemaining {
                                Text(formatTimer(remaining))
                                    .font(.caption2)
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(audioPlayer.sleepTimerMode != .off ? Color.accentColor : .secondary)
                        .frame(width: 45)
                    }
                    
                    Spacer()
                }

                // Centered Playback Buttons
                // Centered Playback Buttons
                HStack(spacing: 45) {
                    Button {
                        audioPlayer.skipBackward(by: 15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 28))
                    }

                    Button {
                        handlePlayButtonPress(track: track)
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                    }

                    Button {
                        audioPlayer.skipForward(by: 30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 28))
                    }
                }
                .buttonStyle(.plain)
                
                // Speed Control aligned to the right
                HStack {
                    Spacer()
                    playbackSpeedControls()
                }
            }

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
                    audioPlayer.notifyFavoriteToggle(for: track.id)
                } label: {
                    Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(track.isFavorite ? .pink : .gray)
                }
                .buttonStyle(.plain)
            }

            if case .baidu = track.location {
                DownloadButton(track: track, collection: collection)
            } else if case .external = track.location {
                DownloadButton(track: track, collection: collection)
            }

            let isCollectionShuffleEnabled = collection.shuffleEnabled

            Button {
                audioPlayer.setShuffleEnabled(
                    !audioPlayer.isShuffleEnabled,
                    for: collection
                )
            } label: {
                Image(systemName: isCollectionShuffleEnabled ? "shuffle.circle.fill" : "shuffle.circle")
                    .font(.title3)
                    .foregroundStyle(isCollectionShuffleEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    isCollectionShuffleEnabled
                    ? NSLocalizedString("shuffle_turn_off", comment: "Turn shuffle off")
                    : NSLocalizedString("shuffle_turn_on", comment: "Turn shuffle on")
                )
            )
            .accessibilityHint(
                Text(NSLocalizedString("shuffle_toggle_hint", comment: "Shuffle toggle hint"))
            )
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
        audioPlayer.seekAndResume(to: time)
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

    private func formatTimer(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
            .prefix(8)
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

    @MainActor
    private func autoGenerateSummaryIfNeeded(for trackId: String, transcriptId: String?) async {
        guard autoGenerateTrackSummaries else { return }
        guard aiGateway.hasValidKey else { return }

        let modelId = aiGateway.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else { return }

        if autoSummaryGuards.contains(trackId) {
            return
        }
        autoSummaryGuards.insert(trackId)
        defer { autoSummaryGuards.remove(trackId) }

        let dbManager = GRDBDatabaseManager.shared

        do {
            try await dbManager.initializeDatabase()

            // Optionally skip short tracks (< 10 minutes)
            if autoSummaryEnforceDurationLimit {
                if let uuid = UUID(uuidString: trackId),
                   let result = try await dbManager.loadTrack(id: uuid) {
                    let duration = result.track.duration ?? 0
                    if duration < 600 {
                        print("[AutoSummary] Skipping track \(trackId): duration \(duration)s < 600s")
                        return
                    }
                }
            }

            if let summary = try await dbManager.fetchTrackSummary(forTrackId: trackId) {
                switch summary.status {
                case .complete:
                    if let transcriptId, summary.transcriptId == transcriptId {
                        return
                    }
                case .generating:
                    return
                case .failed, .idle:
                    break
                }
            }

            let hasPendingJob = (aiGenerationManager.activeJobs + aiGenerationManager.recentJobs).contains { job in
                job.type == .trackSummary && job.trackId == trackId && !job.isTerminal
            }

            guard !hasPendingJob else { return }

            _ = try await aiGenerationManager.enqueueTrackSummaryJob(
                trackId: trackId,
                targetSectionCount: nil,
                includeKeywords: true,
                modelId: modelId
            )
        } catch {
            print("[AutoSummary] Failed to queue summary for track \(trackId): \(error.localizedDescription)")
        }
    }

    // MARK: - Video Player Helpers

    private func handlePlayButtonPress(track: AudiobookTrack) {
        // Play/pause always controls audio playback only
        // Use "Show Video" button to open video player
        audioPlayer.togglePlayback()
    }

    private func openVideoPlayer(for track: AudiobookTrack) {
        guard track.isVideoTrack else { return }

        if PlayableMediaFormat.requiresVLC(forFilename: track.filename) {
            // MKV/WebM -> Use VLC Sheet
            if let url = audioPlayer.currentVLCStreamingURL {
                vlcPlayerURL = url
                vlcPlayerTitle = track.displayName
                showingVLCPlayer = true
            }
        } else {
            // MP4/MOV -> Use Native AVPlayer Sheet (supports PiP)
            showingNativePlayer = true
        }
    }

    private func getVideoURL(for track: AudiobookTrack) -> URL? {
        if PlayableMediaFormat.requiresVLC(forFilename: track.filename) {
            return audioPlayer.currentVLCStreamingURL
        } else {
            return nil
        }
    }
}

struct NativeVideoPlayerSheet: View {
    @ObservedObject var audioPlayer: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let player = audioPlayer.sharedVideoPlayer {
                AVPlayerViewControllerRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }
}

private struct PlaybackProgressObserver: View {
    @EnvironmentObject private var playbackClock: PlaybackClock
    let onTick: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: playbackClock.currentTime) {
                onTick()
            }
    }
}

private struct LiveTimelineView: View {
    @EnvironmentObject private var playbackClock: PlaybackClock
    let seekAction: (Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playbackClock.currentTime },
                    set: { seekAction($0) }
                ),
                in: 0...(max(playbackClock.duration, 1))
            )
            .tint(.accentColor)

            HStack {
                Text(playbackClock.currentTime.formattedTimestamp)
                Spacer()
                Text(playbackClock.duration.formattedTimestamp)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
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
    struct PreviewWrapper: View {
        @StateObject private var library = LibraryStore(autoLoadOnInit: false)
        @StateObject private var player = AudioPlayerViewModel()
        
        var body: some View {
            ContentView()
                .environmentObject(player)
                .environmentObject(player.playbackClock)
                .environmentObject(library)
                .environmentObject(BaiduAuthViewModel())
                .environmentObject(TranscriptionManager())
                .environmentObject(AIGatewayViewModel())
                .environmentObject(AIGenerationManager())
                .environmentObject(TabSelectionManager())
                .task {
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
                        mentionedItems: ["The Great Adventure", "Time Travel Guide"],
                        suggestedCorrections: [
                            "Hero Name": "Ensure the narrator pronounces 'Lin' instead of 'Ling'",
                            "Timeline": "Clarify the flashback happens 5 years earlier"
                        ],
                        sections: sections,
                        modelIdentifier: "gpt-4",
                        jobId: "dummy-job-id"
                    )
                }
        }
    }
    
    return PreviewWrapper()
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
