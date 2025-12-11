import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import GRDB

struct CollectionDetailView: View {
    let collectionID: UUID

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager

    @State private var searchText = ""
    @State private var missingAuthAlert = false
    @State private var showTrackPicker = false
    @State private var trackToDelete: AudiobookTrack?
    @State private var showDeleteConfirmation = false
    @State private var trackToRename: AudiobookTrack?
    @State private var trackTitleDraft = ""
    @State private var showCollectionInfoSheet = false
    @State private var showBatchRename = false
    @State private var collectionTitleDraft = ""
    @State private var collectionDescriptionDraft = ""
    @State private var collectionIsMusicDraft = false
    @State private var trackForTranscription: AudiobookTrack?
    @State private var trackForViewing: AudiobookTrack?
    @State private var trackForReading: AudiobookTrack?
    @State private var trackForTTSProgress: AudiobookTrack?
    @State private var transcriptStatusCache: [UUID: Bool] = [:]
    @State private var pendingAutoFocusTrackId: UUID?
    @State private var didAutoFocusTrack = false
    @State private var trackPendingTranscriptDeletion: AudiobookTrack?
    @State private var showTranscriptDeletionDialog = false
    @State private var transcriptDeletionError: String?
    @State private var showTranscriptDeletionError = false
    @State private var tracksWithSummaries: Set<UUID> = []
    @State private var summaryIndicatorTask: Task<Void, Never>?
    @State private var coverPhotoItem: PhotosPickerItem?
    @State private var showCoverFileImporter = false
    @State private var showCoverPhotosPicker = false
    @State private var isUpdatingCover = false
    @State private var coverUpdateError: String?
    @State private var showCoverUpdateError = false
    @State private var isSummaryVisible = true
    @State private var isLastTrackVisible = false
    @State private var refreshResult: String?
    @State private var showRefreshResult = false
    @State private var candidateTracks: [AudiobookTrack] = []
    @State private var selectedCandidateIds: Set<UUID> = []
    @State private var showRefreshReview = false
    @State private var refreshReviewTitle = ""
    @State private var refreshReviewDescription = ""
    @State private var playbackStateSnapshot: [UUID: TrackPlaybackState] = [:]
    @State private var isDescriptionExpanded = false
    @State private var cachedOrderedTracks: [AudiobookTrack] = []
    @State private var cachedSortedTracks: [AudiobookTrack] = []
    @State private var filterTask: Task<Void, Never>?
    @State private var sortTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var loadedPages: [Int: [AudiobookTrack]] = [:]
    @State private var loadingPages: Set<Int> = []
    @State private var totalPages: Int = 0
    @State private var totalResults: Int = 0
    @State private var isListLoading: Bool = false
    private let pagingThreshold = 1000
    private let pageSize = 500
    @State private var currentQuery: String = ""
    @State private var currentFilterKey: FilterOption = .all
    @State private var currentSortKey: SortOption = .trackNumber

    // MARK: - Filter & Sort Enums
    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case transcribed = "Transcribed"
        case unplayed = "Unplayed"
        case summarized = "Summarized"
        case played = "Played"
        
        var id: String { rawValue }
        
        var localizedName: String {
            switch self {
            case .all: return NSLocalizedString("filter_all", value: "All", comment: "Filter option: All")
            case .transcribed: return NSLocalizedString("filter_transcribed", value: "已转录", comment: "Filter option: Transcribed")
            case .unplayed: return NSLocalizedString("filter_unplayed", value: "未播放", comment: "Filter option: Unplayed")
            case .summarized: return NSLocalizedString("filter_summarized", value: "已总结", comment: "Filter option: Summarized")
            case .played: return NSLocalizedString("filter_played", value: "播放过", comment: "Filter option: Played")
            }
        }
        
        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .transcribed: return "text.bubble"
            case .unplayed: return "circle"
            case .summarized: return "doc.text"
            case .played: return "play.circle"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case trackNumber = "Track Number"
        case titleAscending = "Title Ascending"
        case titleDescending = "Title Descending"
        
        var id: String { rawValue }
        
        var localizedName: String {
            switch self {
            case .trackNumber: return NSLocalizedString("sort_track_number", value: "Track Number", comment: "Sort option: Track Number")
            case .titleAscending: return NSLocalizedString("sort_title_asc", value: "Title Ascending", comment: "Sort option: Title Ascending")
            case .titleDescending: return NSLocalizedString("sort_title_desc", value: "Title Descending", comment: "Sort option: Title Descending")
            }
        }
        
        var icon: String {
            switch self {
            case .trackNumber: return "list.number"
            case .titleAscending: return "arrow.up"
            case .titleDescending: return "arrow.down"
            }
        }
    }

    @State private var selectedFilter: FilterOption = .all
    @State private var selectedSort: SortOption = .trackNumber

    private var collection: AudiobookCollection? {
        library.collections.first { $0.id == collectionID }
    }

    private var isEbookCollection: Bool {
        if let collection, case .ebook = collection.source {
            return true
        }
        return false
    }

    private var canRefreshCurrentCollection: Bool {
        guard let source = collection?.source else { return false }
        switch source {
        case .baiduNetdisk, .rss:
            return true
        default:
            return false
        }
    }

    private var isPagedMode: Bool {
        let countHint = max(
            totalResults,
            collection?.trackCount ?? 0,
            collection?.tracks.count ?? 0
        )
        return countHint > pagingThreshold
    }

    private var sortedTracks: [AudiobookTrack] {
        if isPagedMode {
            return pagedTracks
        } else {
            if !cachedSortedTracks.isEmpty { return cachedSortedTracks }
            guard let collection else { return [] }
            return sortTracks(collection.tracks, by: selectedSort)
        }
    }

    private var pagedTracks: [AudiobookTrack] {
        // Combine loaded pages in order
        let keys = loadedPages.keys.sorted()
        return keys.flatMap { loadedPages[$0] ?? [] }
    }

    private func filterDBKey(for option: FilterOption) -> String {
        switch option {
        case .all: return "all"
        case .transcribed: return "transcribed"
        case .unplayed: return "unplayed"
        case .summarized: return "summarized"
        case .played: return "played"
        }
    }

    private func sortDBKey(for option: SortOption) -> String {
        switch option {
        case .trackNumber: return "trackNumber"
        case .titleAscending: return "titleAscending"
        case .titleDescending: return "titleDescending"
        }
    }

    private func sortTracks(_ tracks: [AudiobookTrack], by option: SortOption) -> [AudiobookTrack] {
        switch option {
        case .trackNumber:
            return tracks.sorted {
                if $0.trackNumber != $1.trackNumber {
                    return $0.trackNumber < $1.trackNumber
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .titleAscending:
            return tracks.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .titleDescending:
            return tracks.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending
            }
        }
    }

    private func updateCachedTracks() {
        // Deprecated: keep for compatibility if called; redirect to scheduled path.
        scheduleFilteredTracksUpdate()
    }

    private func scheduleSortedTracksUpdate() {
        sortTask?.cancel()

        if isPagedMode {
            Task { await reloadFromDatabase(startingPage: 0, focusTarget: pendingAutoFocusTrackId) }
            return
        }

        guard let collection else {
            cachedSortedTracks = []
            scheduleFilteredTracksUpdate()
            return
        }

        let tracks = collection.tracks
        let sortOption = selectedSort

        sortTask = Task.detached {
            let sorted = sortTracks(tracks, by: sortOption)
            if Task.isCancelled { return }
            await MainActor.run {
                cachedSortedTracks = sorted
                scheduleFilteredTracksUpdate()
            }
        }
    }

    private func scheduleFilteredTracksUpdate() {
        filterTask?.cancel()

        if isPagedMode {
            Task {
                await reloadFromDatabase(startingPage: 0, focusTarget: pendingAutoFocusTrackId)
            }
            return
        }

        let base = sortedTracks
        let filter = selectedFilter
        let query = searchText
        let transcriptCache = transcriptStatusCache
        let summaryIds = tracksWithSummaries
        let collectionRef = collection

        filterTask = Task.detached {
            // Compute on a background thread
            let filtered = computeOrderedTracks(from: base, filter: filter, query: query, transcriptCache: transcriptCache, summaryIds: summaryIds, collection: collectionRef)
            if Task.isCancelled { return }
            await MainActor.run {
                cachedOrderedTracks = filtered
                totalResults = filtered.count
            }
        }
    }

    private func computeOrderedTracks(
        from base: [AudiobookTrack],
        filter: FilterOption,
        query: String,
        transcriptCache: [UUID: Bool],
        summaryIds: Set<UUID>,
        collection: AudiobookCollection?
    ) -> [AudiobookTrack] {
        var tracks = base

        if filter != .all {
            tracks = tracks.filter { track in
                switch filter {
                case .all:
                    return true
                case .transcribed:
                    return transcriptCache[track.id] == true
                case .unplayed:
                    let state = collection?.playbackState(for: track.id)
                    return state == nil || state!.position < 1
                case .summarized:
                    return summaryIds.contains(track.id)
                case .played:
                    if let state = collection?.playbackState(for: track.id) {
                        return state.position >= 1
                    }
                    return false
                }
            }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tracks }

        return tracks.filter { track in
            track.displayName.localizedCaseInsensitiveContains(trimmed) ||
            track.filename.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var filteredTracks: [AudiobookTrack] {
        cachedOrderedTracks
    }

    private var showScrollToTopButton: Bool {
        !isSummaryVisible
    }

    private var showScrollToBottomButton: Bool {
        guard !isPagedMode else { return false }
        guard !filteredTracks.isEmpty else { return false }
        return !isLastTrackVisible
    }

    var body: some View {
        let baseView = content
            .navigationTitle(collection?.title ?? NSLocalizedString("collection_title_fallback", comment: "Collection detail fallback title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: Text(NSLocalizedString("search_tracks_prompt", comment: "Search tracks prompt"))
            )
            .toolbar {
                if library.canModifyCollection(collectionID) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(action: addTracksAction) {
                                Label(
                                    NSLocalizedString("add_tracks_button", comment: "Add tracks button"),
                                    systemImage: "plus.circle"
                                )
                            }
                            
                            if canRefreshCurrentCollection {
                                Button(action: refreshCollectionAction) {
                                    Label(NSLocalizedString("refresh_collection_button", value: "Refresh Collection", comment: "Refresh collection button"), systemImage: "arrow.clockwise")
                                }
                            }
                            
                            Button(action: { showBatchRename = true }) {
                                Label("Batch Rename", systemImage: "pencil.and.list.clipboard")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }

        let viewWithAlerts = baseView
            .alert(NSLocalizedString("connect_baidu_first", comment: "Connect Baidu First alert"), isPresented: $missingAuthAlert) {
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("sign_in_on_sources_tab", comment: "Sign in on sources tab message"))
            }
            .alert(
                NSLocalizedString("remove_track_action", comment: "Remove track dialog title"),
                isPresented: $showDeleteConfirmation,
                presenting: trackToDelete
            ) { _ in
                Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) {
                    trackToDelete = nil
                }
                Button(NSLocalizedString("remove_track_action", comment: "Remove track action label"), role: .destructive) {
                    deleteSelectedTrack()
                }
            } message: { track in
                Text(removePrompt(for: track))
            }
            .alert(
                NSLocalizedString("delete_transcript_confirm_title", comment: "Delete transcript dialog title"),
                isPresented: $showTranscriptDeletionDialog,
                presenting: trackPendingTranscriptDeletion
            ) { track in
                Button(NSLocalizedString("delete_transcript_cancel", comment: "Cancel delete transcript"), role: .cancel) {
                    trackPendingTranscriptDeletion = nil
                }
                Button(NSLocalizedString("delete_transcript_confirm", comment: "Confirm delete transcript"), role: .destructive) {
                    deleteTranscript(for: track)
                }
            } message: { track in
                Text(String(format: NSLocalizedString("delete_transcript_confirm_message", comment: "Delete transcript confirm message"), track.displayName))
            }
            .alert(
                NSLocalizedString("error_title", comment: "Generic error title"),
                isPresented: $showTranscriptDeletionError,
                presenting: transcriptDeletionError
            ) { _ in
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) {
                    showTranscriptDeletionError = false
                }
            } message: { error in
                Text(error)
            }
            .alert(
                NSLocalizedString("cover_update_failed_title", comment: "Cover update failed title"),
                isPresented: $showCoverUpdateError,
                presenting: coverUpdateError
            ) { _ in
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) {
                    showCoverUpdateError = false
                }
            } message: { error in
                Text(error)
            }
            .alert(
                "Generate Audio",
                isPresented: $audioPlayer.showGenerateAudioConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    audioPlayer.showGenerateAudioConfirmation = false
                    audioPlayer.trackToGenerateAudio = nil
                }
                Button("Generate") {
                    if let track = audioPlayer.trackToGenerateAudio, let collection = collection {
                        audioPlayer.generateAudio(for: track, in: collection, autoPlay: true)
                    }
                    audioPlayer.showGenerateAudioConfirmation = false
                    audioPlayer.trackToGenerateAudio = nil
                }
            } message: {
                if let track = audioPlayer.trackToGenerateAudio {
                    Text("Audio has not been generated for \"\(track.displayName)\". Would you like to generate it now?")
                }
            }
            .alert(
                "Collection Refresh",
                isPresented: $showRefreshResult,
                presenting: refreshResult
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { result in
                Text(result)
            }

        let viewWithSheets = viewWithAlerts
            .sheet(isPresented: $showTrackPicker) {
                TrackPickerView(
                    collectionID: collectionID,
                    onTracksSelected: { newTracks in
                        library.addTracksToCollection(
                            collectionID: collectionID,
                            newTracks: newTracks
                        )
                    }
                )
                .environmentObject(library)
                .environmentObject(authViewModel)
            }
            .sheet(item: $trackToRename) { track in
                RenameEntryView(
                    title: NSLocalizedString("rename_track_title", comment: "Rename track title"),
                    fieldLabel: NSLocalizedString("name_field_label", comment: "Name field label"),
                    text: $trackTitleDraft,
                    onSubmit: {
                        applyTrackRename(for: track)
                    },
                    onCancel: cancelTrackRename
                )
            }
            .sheet(isPresented: $showCollectionInfoSheet) {
                CollectionInfoEditorView(
                    title: NSLocalizedString("edit_collection_details_title", comment: "Edit collection details title"),
                    nameFieldLabel: NSLocalizedString("name_field_label", comment: "Name field label"),
                    descriptionFieldLabel: NSLocalizedString("collection_description_field_label", comment: "Collection description field label"),
                    name: $collectionTitleDraft,
                    description: $collectionDescriptionDraft,
                    isMusic: $collectionIsMusicDraft,
                    onSubmit: applyCollectionDetailsUpdate,
                    onCancel: cancelCollectionDetailsEdit
                )
            }
            .sheet(item: $trackForTranscription) { track in
                TranscriptionSheet(
                    track: track,
                    collectionID: collectionID,
                    collectionTitle: collection?.title ?? "",
                    collectionDescription: collection?.description
                )
            }
            .sheet(item: $trackForTTSProgress) { track in
                TTSJobProgressSheet(track: track)
            }
            .sheet(item: $trackForViewing) { track in
                TranscriptViewerSheet(trackId: track.id.uuidString, trackName: track.displayName, showTrackSummary: true)
            }
            .sheet(item: $trackForReading) { track in
                if let collection = collection {
                    NavigationStack {
                        EbookReaderView(track: track, collection: collection)
                    }
                }
            }
            .sheet(isPresented: $showBatchRename) {
                if let collection = collection {
                    BatchRenameView(
                        tracks: collection.tracks,
                        onApply: { changes in
                            library.batchRenameTracks(in: collectionID, changes: changes)
                            showBatchRename = false
                        },
                        onCancel: {
                            showBatchRename = false
                        }
                    )
                }
            }
            .photosPicker(isPresented: $showCoverPhotosPicker, selection: $coverPhotoItem, matching: .images)
            .fileImporter(isPresented: $showCoverFileImporter, allowedContentTypes: [.image]) { result in
                handleCoverFileImport(result)
            }
            .sheet(isPresented: $showRefreshReview) {
                NavigationStack {
                    CollectionReviewView(
                        title: $refreshReviewTitle,
                        description: $refreshReviewDescription,
                        tracks: candidateTracks,
                        selectedTrackIds: $selectedCandidateIds,
                        totalSize: candidateTracks.reduce(0) { $0 + $1.fileSize },
                        nonPlayableFiles: [],
                        saveButtonTitle: NSLocalizedString("add_tracks_button", comment: "Add Tracks"),
                        onSave: {
                            let selected = candidateTracks.filter { selectedCandidateIds.contains($0.id) }
                            library.addTracks(to: collectionID, tracks: selected)
                            
                            if let collection = collection, (refreshReviewTitle != collection.title || refreshReviewDescription != (collection.description ?? "")) {
                                library.updateCollectionDetails(
                                    collectionID: collectionID,
                                    newTitle: refreshReviewTitle,
                                    newDescription: refreshReviewDescription.isEmpty ? nil : refreshReviewDescription,
                                    shouldUpdateDescription: true
                                )
                            }
                            
                            showRefreshReview = false
                            refreshResult = String(format: NSLocalizedString("refresh_success_message", value: "Added %d tracks.", comment: "Refresh success"), selected.count)
                            showRefreshResult = true
                        }
                    ) { track in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.displayName)
                                    .font(.body)
                                    .lineLimit(2)

                                Text(formatBytes(track.fileSize))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("\(track.trackNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .navigationTitle(NSLocalizedString("review_new_tracks_title", value: "New Tracks", comment: "Review new tracks title"))
                    .toolbar {
                         ToolbarItem(placement: .cancellationAction) {
                             Button(NSLocalizedString("cancel_button", comment: "Cancel")) { showRefreshReview = false }
                         }
                    }
                }
            }

        let viewWithPlaybackEvents = viewWithSheets
            .onChange(of: audioPlayer.currentTrack?.id) { _ in
                let currentCollection = self.collection
                
                if
                    audioPlayer.activeCollection?.id == collectionID,
                    let collection = currentCollection,
                    let track = audioPlayer.currentTrack
                {
                    // Always record when track changes
                    recordPlayback(for: collection, track: track, position: audioPlayer.currentTime)
                }

                prepareAutoFocusTargetIfNeeded(for: currentCollection)
            }
            .onChange(of: audioPlayer.currentTime) { newValue in
                guard
                    audioPlayer.activeCollection?.id == collectionID,
                    let collection,
                    let track = audioPlayer.currentTrack
                else { return }

                // Throttle updates: only record every 5 seconds or if playback is paused (handled elsewhere usually, but good to be safe)
                // We check if the integer value is a multiple of 5 to approximate 5-second intervals
                if Int(newValue) % 5 == 0 {
                    recordPlayback(for: collection, track: track, position: newValue)
                }
            }

        let viewWithStateEvents = viewWithPlaybackEvents
            .onChange(of: trackToRename) { newValue in
                if newValue == nil {
                    trackTitleDraft = ""
                }
            }
            .onChange(of: showCollectionInfoSheet) { newValue in
                if !newValue {
                    collectionTitleDraft = ""
                    collectionDescriptionDraft = ""
                }
            }
            .onChange(of: collectionID) { _ in
                resetAutoFocusState()
                loadTranscriptStatus()
                prepareAutoFocusTargetIfNeeded(for: self.collection)
                refreshTrackSummaryIndicators(for: self.collection)
                refreshPlaybackStateSnapshot(for: self.collection)
            }
            .onChange(of: collection?.tracks.map(\.id) ?? []) { _ in
                prepareAutoFocusTargetIfNeeded(for: self.collection)
                refreshTrackSummaryIndicators(for: self.collection)
                refreshPlaybackStateSnapshot(for: self.collection)
            }
            .onChange(of: audioPlayer.activeCollection?.id) { _ in
                prepareAutoFocusTargetIfNeeded(for: self.collection)
            }
            .onChange(of: coverPhotoItem) { newItem in
                guard let newItem else { return }
                handlePhotosPickerSelection(newItem)
            }

        return viewWithStateEvents
            .onAppear {
                refreshSttTranscribingTrackIds(from: transcriptionManager.activeJobs)
                refreshTTSGeneratingTrackIds(from: transcriptionManager.activeJobs)

                loadTranscriptStatus()
                prepareAutoFocusTargetIfNeeded(for: self.collection)
                refreshTrackSummaryIndicators(for: self.collection)
                refreshPlaybackStateSnapshot(for: self.collection)
                
                // Trigger lazy load
                Task {
                    await library.ensureCollectionLoaded(collectionID)
                    await MainActor.run {
                        refreshPlaybackStateSnapshot(for: self.collection)
                        currentQuery = searchText
                        currentFilterKey = selectedFilter
                        currentSortKey = selectedSort
                    }
                    await reloadFromDatabase(startingPage: 0, focusTarget: pendingAutoFocusTrackId)
                }
            }
            .onChange(of: collection?.tracks) { _ in scheduleSortedTracksUpdate() }
            .onChange(of: searchText) { _ in
                // Debounce search to avoid hammering DB per keystroke
                searchDebounceTask?.cancel()
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run { scheduleFilteredTracksUpdate() }
                }
            }
            .onSubmit(of: .search) {
                searchDebounceTask?.cancel()
                scheduleFilteredTracksUpdate()
            }
            .onChange(of: selectedFilter) { _ in scheduleFilteredTracksUpdate() }
            .onChange(of: selectedSort) { _ in scheduleSortedTracksUpdate() }
            .onChange(of: transcriptStatusCache) { _ in scheduleFilteredTracksUpdate() }
            .onChange(of: tracksWithSummaries) { _ in scheduleFilteredTracksUpdate() }
            .onReceive(transcriptionManager.$activeJobs) { jobs in
                refreshSttTranscribingTrackIds(from: jobs)
                refreshTTSGeneratingTrackIds(from: jobs)
            }
            .onChange(of: aiGenerationManager.activeJobs) { jobs in
                guard jobs.contains(where: { $0.type == .trackSummary }) else { return }
                refreshTrackSummaryIndicators(for: self.collection)
            }
            .onChange(of: aiGenerationManager.recentJobs) { jobs in
                guard jobs.contains(where: { $0.type == .trackSummary }) else { return }
                refreshTrackSummaryIndicators(for: self.collection)
            }
            .onDisappear {
                summaryIndicatorTask?.cancel()
                summaryIndicatorTask = nil
                filterTask?.cancel()
                sortTask?.cancel()
                cachedOrderedTracks = []
                cachedSortedTracks = []
                transcriptStatusCache = [:]
                tracksWithSummaries = []
                playbackStateSnapshot = [:]
                loadedPages = [:]
                loadingPages = []
                totalPages = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { notification in
                print("[CollectionDetailView] Received TranscriptionCompleted notification")
                // Reload transcript status when a transcription completes
                loadTranscriptStatus()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let collection {
            listContent(collection)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("collection_not_found", comment: "Collection not found"))
                    .font(.headline)

                Text(NSLocalizedString("collection_not_found_message", comment: "Collection not found message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func listContent(_ collection: AudiobookCollection) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .center) {
                List {
                    summarySection(collection)
                        .id("summary-section")
                    tracksSection(collection)
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    prepareAutoFocusTargetIfNeeded(for: collection)
                    attemptAutoFocusIfNeeded(using: proxy)
                }
                .onChange(of: pendingAutoFocusTrackId) { _ in
                    attemptAutoFocusIfNeeded(using: proxy)
                }
                .onChange(of: filteredTracks.map(\.id)) { _ in
                    attemptAutoFocusIfNeeded(using: proxy)
                    isLastTrackVisible = false
                }
                
                // Jump to Top/Bottom Buttons (Centered)
                if filteredTracks.count > 10 && (showScrollToTopButton || showScrollToBottomButton) {
                    VStack {
                        if showScrollToTopButton {
                            Button {
                                withAnimation {
                                    proxy.scrollTo("summary-section", anchor: .top)
                                }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.1), radius: 3)
                            }
                            .padding(.top, 8)
                            .accessibilityLabel(Text("Scroll to top"))
                        }
                        
                        Spacer()
                        
                        if showScrollToBottomButton {
                            Button {
                                if isPagedMode {
                                    let maxLoaded = loadedPages.keys.max() ?? 0
                                    let nextPage = maxLoaded + 1
                                    if nextPage < totalPages {
                                        Task {
                                            await loadPage(nextPage)
                                            await MainActor.run {
                                                if let last = filteredTracks.last {
                                                    withAnimation {
                                                        proxy.scrollTo(last.id, anchor: .bottom)
                                                    }
                                                }
                                            }
                                        }
                                        return
                                    }
                                }
                                
                                if let last = filteredTracks.last {
                                    withAnimation {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.1), radius: 3)
                            }
                            .padding(.bottom, 8)
                            .accessibilityLabel(Text("Scroll to bottom"))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ collection: AudiobookCollection) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    coverEditor(for: collection)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(collection.title)
                                .font(.title3)
                                .bold()
                                .multilineTextAlignment(.leading)
                            if case .ebook = collection.source {
                                Image(systemName: "book")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .accessibilityLabel(NSLocalizedString("ebook_collection_indicator_accessibility", comment: "Indicator for ebook collection"))
                            } else if case .rss = collection.source {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(NSLocalizedString("rss_collection_indicator_accessibility", value: "RSS collection", comment: "Indicator for RSS collection"))
                            } else if collection.isMusic {
                                Image(systemName: "music.note")
                                    .font(.title3)
                                    .foregroundStyle(.pink)
                                    .accessibilityLabel("Music Collection")
                            }
                        }

                        if case .ebook = collection.source, let charCount = collection.totalCharacterCount {
                            Text("\(collection.trackCount) tracks • \(formatNumber(charCount)) chars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            let totalSize = collection.tracks.reduce(into: Int64(0)) { $0 += $1.fileSize }
                            Text(String(format: NSLocalizedString("track_count_and_size", comment: "Track count and size"), collection.trackCount, formatBytes(totalSize)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if collection.description?.isEmpty != false, library.canModifyCollection(collectionID) {
                            Button {
                                beginEditingCollectionDetails(collection)
                            } label: {
                                Label(
                                    NSLocalizedString("add_description_button", comment: "Add description button"),
                                    systemImage: "plus.circle"
                                )
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    if library.canModifyCollection(collectionID) {
                        Menu {
                            Button {
                                beginEditingCollectionDetails(collection)
                            } label: {
                                Label(
                                    NSLocalizedString("edit_collection_details_action", comment: "Edit collection details action"),
                                    systemImage: "pencil"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.large)
                                .padding(.leading, 8)
                                .padding(.top, 2)
                                .accessibilityLabel(NSLocalizedString("more_options_accessibility", comment: "More options accessibility label"))
                        }
                    }
                }

                if let description = collection.description, !description.isEmpty {
                    CollectionDescriptionView(
                        description: description,
                        isExpanded: $isDescriptionExpanded
                    )
                } else {
                    Text(NSLocalizedString("collection_description_empty", comment: "Collection description empty placeholder"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: collection.id) { _ in
            isDescriptionExpanded = false
        }
        .onChange(of: collection.description ?? "") { _ in
            isDescriptionExpanded = false
        }
        .onAppear {
            isSummaryVisible = true
        }
        .onDisappear {
            isSummaryVisible = false
        }
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        
        if number >= 1_000_000 {
            let millions = Double(number) / 1_000_000
            return "\(formatter.string(from: NSNumber(value: millions)) ?? "")M"
        } else if number >= 1_000 {
            let thousands = Double(number) / 1_000
            return "\(formatter.string(from: NSNumber(value: thousands)) ?? "")k"
        } else {
            return "\(number)"
        }
    }

    private var tracksHeader: some View {
        HStack {
            Text(NSLocalizedString("tracks_header", value: "Tracks", comment: "Tracks section header"))
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
            
            Spacer()
            
            Menu {
                Section {
                    ForEach(FilterOption.allCases) { option in
                        Button {
                            selectedFilter = option
                        } label: {
                            if selectedFilter == option {
                                Label(option.localizedName, systemImage: "checkmark")
                            } else {
                                Label(option.localizedName, systemImage: option.icon)
                            }
                        }
                    }
                } header: {
                    Text("Filter")
                }
                
                Section {
                    ForEach(SortOption.allCases) { option in
                        Button {
                            selectedSort = option
                        } label: {
                            if selectedSort == option {
                                Label(option.localizedName, systemImage: "checkmark")
                            } else {
                                Label(option.localizedName, systemImage: option.icon)
                            }
                        }
                    }
                } header: {
                    Text("Sort")
                }
            } label: {
                Image(systemName: selectedFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(selectedFilter == .all ? .secondary : Color.accentColor)
            }
        }
    }

    private func coverEditor(for collection: AudiobookCollection) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CollectionCoverArtView(
                cover: collection.coverAsset,
                title: collection.title,
                size: 110,
                cornerRadius: 20
            )
            .id(collection.updatedAt)
            .shadow(color: Color.black.opacity(0.1), radius: 6, y: 3)

            if isUpdatingCover {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if library.canModifyCollection(collectionID) {
                coverMenu(for: collection)
            }
        }
    }

    private func coverMenu(for collection: AudiobookCollection) -> some View {
        Menu {
            Button {
                showCoverPhotosPicker = true
            } label: {
                Label(
                    NSLocalizedString("collection_cover_choose_photo", comment: "Choose cover from photos"),
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            Button {
                showCoverFileImporter = true
            } label: {
                Label(
                    NSLocalizedString("collection_cover_import_files", comment: "Import cover from files"),
                    systemImage: "folder.badge.plus"
                )
            }
            if case .image = collection.coverAsset.kind {
                Button(role: .destructive) {
                    resetCollectionCoverArtwork()
                } label: {
                    Label(
                        NSLocalizedString("collection_cover_reset_action", comment: "Reset cover to default"),
                        systemImage: "arrow.uturn.backward"
                    )
                }
            }
        } label: {
            Image(systemName: "camera.fill")
                .imageScale(.medium)
                .padding(8)
                .background(.thinMaterial, in: Circle())
                .padding(6)
        }
        .disabled(isUpdatingCover)
        .accessibilityLabel(Text(NSLocalizedString("collection_cover_edit_accessibility", comment: "Edit cover accessibility label")))
    }

    @ViewBuilder
    private func tracksSection(_ collection: AudiobookCollection) -> some View {
        let tracks = filteredTracks
        Section(header: tracksHeader) {
            if tracks.isEmpty {
                if isListLoading || (collection.tracks.isEmpty && collection.trackCount > 0) {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                } else {
                    Text(searchText.isEmpty ? NSLocalizedString("no_audio_tracks", comment: "No audio tracks") : String(format: NSLocalizedString("no_search_results", comment: "No search results"), searchText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    let trackIsActive = isCurrentTrack(track: track)
                    let hasTranscript = transcriptStatusCache[track.id] ?? false
                    let isTranscribingTrack = sttTranscribingTrackIds.contains(track.id)

                    TrackDetailRow(
                        index: index,
                        track: track,
                        collection: collection,
                        isActive: trackIsActive,
                        isPlaying: trackIsActive && audioPlayer.isPlaying,
                        playbackState: playbackStateSnapshot[track.id],
                        isFavorite: track.isFavorite,
                        hasTranscript: hasTranscript,
                        hasSummary: tracksWithSummaries.contains(track.id),
                        isTranscribing: isTranscribingTrack,
                        onSelect: {
                            startPlayback(track, in: collection)
                        },
                        onToggleFavorite: {
                            library.toggleFavorite(for: track.id, in: collection.id)
                            audioPlayer.notifyFavoriteToggle(for: track.id)
                        }
                    )
                    .equatable()
                    .onAppear {
                        if index == tracks.count - 1 {
                            isLastTrackVisible = true
                            // Load next page when bottom is reached in paged mode
                            if isPagedMode {
                                let currentPage = loadedPages.keys.sorted().last ?? 0
                                Task { await loadPage(currentPage + 1) }
                            }
                        }
                    }
                    .onDisappear {
                        if index == tracks.count - 1 {
                            isLastTrackVisible = false
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        favoriteSwipeButton(for: track, in: collection)
                    }
                    .swipeActions(edge: .trailing) {
                        if library.canModifyCollection(collectionID) {
                            Button {
                                beginRenamingTrack(track)
                            } label: {
                                Label(
                                    NSLocalizedString("rename_action", comment: "Rename action"),
                                    systemImage: "pencil"
                                )
                            }
                            .labelStyle(.iconOnly)

                            Button(role: .destructive) {
                                confirmDeleteTrack(track)
                            } label: {
                                Label(
                                    NSLocalizedString("remove_track_action", comment: "Remove track swipe action"),
                                    systemImage: "trash"
                                )
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    .contextMenu {
                        // Add Read option for text tracks
                        if case .text = track.location {
                            Button {
                                trackForReading = track
                            } label: {
                                Label("Read", systemImage: "book")
                            }

                            if ttsGeneratingTrackIds.contains(track.id) {
                                Button {
                                    trackForTTSProgress = track
                                } label: {
                                    Label("View TTS progress", systemImage: "waveform.path.ecg")
                                }
                            } else {
                                Button {
                                    trackForTTSProgress = track
                                    Task {
                                        await audioPlayer.generateAudio(for: track, in: collection)
                                    }
                                } label: {
                                    Label(NSLocalizedString("generate_audio_action", value: "Generate Audio", comment: "Generate audio action"), systemImage: "waveform.badge.plus")
                                }
                            }
                        } else if case .cachedText = track.location {
                            Button {
                                trackForReading = track
                            } label: {
                                Label("Read", systemImage: "book")
                            }
                            // Already generated, maybe offer re-generate?
                        }

                        if isTranscribingTrack {
                            Button {
                                trackForTranscription = track
                            } label: {
                                Label(
                                    NSLocalizedString("transcription_view_running_job", comment: "View running transcription"),
                                    systemImage: "waveform.badge.exclamationmark"
                                )
                            }
                        } else if !hasTranscript && !track.isTextTrack { // Hide transcribe for text tracks
                            Button {
                                trackForTranscription = track
                            } label: {
                                Label(
                                    NSLocalizedString("transcribe_track_title", comment: "Transcribe track title"),
                                    systemImage: "waveform"
                                )
                            }
                        }

                        if hasTranscript {
                            Button {
                                trackForViewing = track
                            } label: {
                                Label(
                                    NSLocalizedString("view_transcript", comment: "View transcript menu item"),
                                    systemImage: "text.alignleft"
                                )
                            }

                            if library.canModifyCollection(collectionID) && !isEbookCollection {
                                Button(role: .destructive) {
                                    confirmDeleteTranscript(track)
                                } label: {
                                    Label(
                                        NSLocalizedString("delete_transcript", comment: "Delete transcript menu item"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                        }
                    } preview: {
                        Text(track.displayName)
                            .font(.subheadline)
                            .padding()
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .frame(maxWidth: 340)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func refreshTrackSummaryIndicators(for collection: AudiobookCollection?) {
        summaryIndicatorTask?.cancel()

        guard let collection else {
            tracksWithSummaries = []
            summaryIndicatorTask = nil
            return
        }

        let trackIds: [String]
        if isPagedMode {
            trackIds = pagedTracks.map { $0.id.uuidString }
        } else {
            trackIds = collection.tracks.map { $0.id.uuidString }
        }
        guard !trackIds.isEmpty else {
            tracksWithSummaries = []
            summaryIndicatorTask = nil
            return
        }

        let task = Task.detached { [trackIds] in
            // Debounce: wait 500ms before querying
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if Task.isCancelled { return }

            var readyTrackIds = Set<UUID>()
            do {
                let batchSize = 500
                var completedStrings: Set<String> = []
                var index = 0
                while index < trackIds.count {
                    if Task.isCancelled { return }
                    let end = min(index + batchSize, trackIds.count)
                    let batch = Array(trackIds[index..<end])
                    let completedIds = try await GRDBDatabaseManager.shared.fetchTrackIdsWithCompletedSummaries(trackIds: batch)
                    completedStrings.formUnion(completedIds)
                    index = end
                }
                readyTrackIds = Set(completedStrings.compactMap { UUID(uuidString: $0) })
            } catch {
                print("[CollectionDetailView] Failed to refresh summary indicators: \(error.localizedDescription)")
            }
            
            if Task.isCancelled { return }

            await MainActor.run {
                tracksWithSummaries = readyTrackIds
            }
        }

        summaryIndicatorTask = task
    }

    private func prepareAutoFocusTargetIfNeeded(for collection: AudiobookCollection?) {
        guard !didAutoFocusTrack else { return }

        guard let target = resolveAutoFocusTrackID(for: collection) else {
            if pendingAutoFocusTrackId != nil {
                pendingAutoFocusTrackId = nil
            }
            return
        }

        if pendingAutoFocusTrackId != target {
            pendingAutoFocusTrackId = target
        }
    }

    private func resetAutoFocusState() {
        pendingAutoFocusTrackId = nil
        didAutoFocusTrack = false
    }

    private func refreshPlaybackStateSnapshot(for collection: AudiobookCollection?) {
        guard let collection else {
            playbackStateSnapshot = [:]
            return
        }
        playbackStateSnapshot = collection.playbackStates
    }

    private func resolveAutoFocusTrackID(for collection: AudiobookCollection?) -> UUID? {
        guard let collection else { return nil }

        if
            audioPlayer.activeCollection?.id == collection.id,
            let activeId = audioPlayer.currentTrack?.id,
            collection.tracks.contains(where: { $0.id == activeId })
        {
            return activeId
        }

        if
            let lastPlayed = collection.lastPlayedTrackId,
            collection.tracks.contains(where: { $0.id == lastPlayed })
        {
            return lastPlayed
        }

        return nil
    }

    private func attemptAutoFocusIfNeeded(using proxy: ScrollViewProxy?) {
        guard
            !didAutoFocusTrack,
            let targetId = pendingAutoFocusTrackId,
            filteredTracks.contains(where: { $0.id == targetId }),
            !isPagedMode, // disable autofocus for large/paged collections
            !isListLoading,
            loadingPages.isEmpty
        else { return }

        // If proxy is nil (paging load context), skip scroll but mark ready
        guard let proxy else {
            didAutoFocusTrack = true
            return
        }

        // Mark as focused immediately to avoid multiple rapid scrolls
        didAutoFocusTrack = true

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
            pendingAutoFocusTrackId = nil
        }
    }

    private func startPlayback(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        // Don't modify 'missingAuthAlert' here. AudioPlayerViewModel will handle missing token errors if needed.
        // We pass the optional token. If it's nil and the track requires streaming, AudioPlayer will fail gracefully.
        // If the track is cached or local, it will play successfully.
        
        if audioPlayer.currentTrack?.id == track.id, audioPlayer.isPlaying {
            audioPlayer.togglePlayback()
        } else {
            audioPlayer.play(track: track, in: collection, token: authViewModel.token)
            recordPlayback(for: collection, track: track, position: audioPlayer.currentTime)
        }
    }

    private func isCurrentTrack(track: AudiobookTrack) -> Bool {
        audioPlayer.currentTrack?.id == track.id && audioPlayer.activeCollection?.id == collectionID
    }

    private func hasNextTrack(_ track: AudiobookTrack) -> Bool {
        nextTrack(after: track) != nil
    }

    private func hasPreviousTrack(_ track: AudiobookTrack) -> Bool {
        previousTrack(before: track) != nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func recordPlayback(for collection: AudiobookCollection, track: AudiobookTrack, position: Double) {
        library.recordPlaybackProgress(
            collectionID: collection.id,
            trackID: track.id,
            position: position,
            duration: audioPlayer.duration
        )
    }

    private func handlePlayPause(for track: AudiobookTrack, in collection: AudiobookCollection) {
        if audioPlayer.hasActivePlayer, audioPlayer.currentTrack?.id == track.id {
            audioPlayer.togglePlayback()
        } else {
            startPlayback(track, in: collection)
        }
    }

    private func handlePreviousButton(for track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let target = previousTrack(before: track) else { return }
        if audioPlayer.hasActivePlayer, audioPlayer.currentTrack?.id == track.id {
            audioPlayer.playPreviousTrack()
        } else {
            startPlayback(target, in: collection)
        }
    }

    private func handleNextButton(for track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let target = nextTrack(after: track) else { return }
        if audioPlayer.hasActivePlayer, audioPlayer.currentTrack?.id == track.id {
            audioPlayer.playNextTrack()
        } else {
            startPlayback(target, in: collection)
        }
    }

    private func confirmDeleteTrack(_ track: AudiobookTrack) {
        trackToDelete = track
        showDeleteConfirmation = true
    }

    private func beginRenamingTrack(_ track: AudiobookTrack) {
        trackToRename = track
        trackTitleDraft = String(track.displayName.prefix(256))
    }

    private func cancelTrackRename() {
        trackToRename = nil
        trackTitleDraft = ""
    }

    private func applyTrackRename(for track: AudiobookTrack) {
        let trimmed = trackTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        trackTitleDraft = ""
        trackToRename = nil

        guard !trimmed.isEmpty else { return }
        library.renameTrack(
            in: collectionID,
            trackID: track.id,
            newTitle: String(trimmed.prefix(256))
        )
    }

    private func beginEditingCollectionDetails(_ collection: AudiobookCollection) {
        collectionTitleDraft = String(collection.title.prefix(256))
        collectionDescriptionDraft = String((collection.description ?? "").prefix(1024))
        collectionIsMusicDraft = collection.isMusic
        showCollectionInfoSheet = true
    }

    private func cancelCollectionDetailsEdit() {
        showCollectionInfoSheet = false
        collectionTitleDraft = ""
        collectionDescriptionDraft = ""
    }

    private func applyCollectionDetailsUpdate() {
        guard let collection else {
            cancelCollectionDetailsEdit()
            return
        }

        let trimmedTitle = collectionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = collectionDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        collectionTitleDraft = ""
        collectionDescriptionDraft = ""
        showCollectionInfoSheet = false

        guard !trimmedTitle.isEmpty else { return }

        let clampedTitle = String(trimmedTitle.prefix(256))
        let clampedDescription = trimmedDescription.isEmpty ? nil : String(trimmedDescription.prefix(1024))

        guard clampedTitle != collection.title || clampedDescription != collection.description || collectionIsMusicDraft != collection.isMusic else { return }

        library.updateCollectionDetails(
            collectionID: collectionID,
            newTitle: clampedTitle,
            newDescription: clampedDescription,
            shouldUpdateDescription: true,
            isMusic: collectionIsMusicDraft
        )
    }

    private func deleteSelectedTrack() {
        guard let track = trackToDelete else { return }
        library.removeTrackFromCollection(
            collectionID: collectionID,
            trackID: track.id
        )
        trackToDelete = nil
    }

    private func addTracksAction() {
        showTrackPicker = true
    }
    
    // MARK: - Paging Helpers

    private func pageIndexForTrack(collectionId: UUID, trackId: UUID, total: Int) -> Int? {
        do {
            if let trackNumber = try GRDBDatabaseManager.shared.fetchTrackNumber(collectionId: collectionId, trackId: trackId) {
                return max(0, (trackNumber - 1) / pageSize)
            }
        } catch {
            print("[CollectionDetailView] Failed to fetch track number: \(error)")
        }
        return nil
    }

    @MainActor
    private func updateLoadedPages(_ page: Int, tracks: [AudiobookTrack]) {
        loadedPages[page] = tracks
        // Keep a small window to limit memory; always retain first page.
        let keep = [page - 1, page, page + 1, 0].filter { $0 >= 0 }
        loadedPages = loadedPages.filter { keep.contains($0.key) }
        cachedOrderedTracks = pagedTracks
    }

    private func loadPage(_ page: Int) async {
        guard !loadingPages.contains(page) else { return }
        guard page >= 0 else { return }
        if totalPages > 0, page >= totalPages { return }
        guard let collection else { return }

        await MainActor.run { loadingPages.insert(page) }
        defer {
            Task { @MainActor in loadingPages.remove(page) }
        }

        do {
            let offset = page * pageSize
            let (tracks, total) = try await GRDBDatabaseManager.shared.fetchTracks(
                collectionId: collection.id,
                query: currentQuery,
                filter: filterDBKey(for: currentFilterKey),
                sort: sortDBKey(for: currentSortKey),
                offset: offset,
                limit: pageSize
            )

            let states = try await GRDBDatabaseManager.shared.fetchPlaybackStates(collectionId: collection.id, trackIds: tracks.map { $0.id })
            await MainActor.run {
                totalResults = total
                totalPages = Int(ceil(Double(totalResults) / Double(pageSize)))
                // Merge playback state snapshot for these tracks
                for (id, state) in states {
                    playbackStateSnapshot[id] = state
                }
                updateLoadedPages(page, tracks: tracks)
                if page == 0 {
                    isListLoading = false
                }
                // Refresh status caches for visible pages only
                loadTranscriptStatus()
                refreshTrackSummaryIndicators(for: collection)
            }
        } catch {
            print("[CollectionDetailView] Failed to load page \(page): \(error)")
            if page == 0 {
                await MainActor.run {
                    isListLoading = false
                }
            }
        }
    }

    @MainActor
    private func resetPagingState(clearCaches: Bool = false) {
        loadedPages = [:]
        loadingPages = []
        totalPages = 0
        totalResults = 0
        if clearCaches {
            cachedOrderedTracks = []
            cachedSortedTracks = []
        }
    }

    private func reloadFromDatabase(startingPage: Int, focusTarget: UUID?) async {
        await MainActor.run {
            isListLoading = true
        }

        resetPagingState(clearCaches: false)
        currentQuery = searchText
        currentFilterKey = selectedFilter
        currentSortKey = selectedSort

        // Always load first page; we no longer preload neighbors to reduce jank.
        await loadPage(0)

        // Only attempt autofocus for non-paged collections; large collections skip it.
        await MainActor.run {
            pendingAutoFocusTrackId = isPagedMode ? nil : focusTarget
            didAutoFocusTrack = false
            isListLoading = false
        }

        if !isPagedMode, focusTarget != nil {
            await MainActor.run {
                attemptAutoFocusIfNeeded(using: nil)
            }
        }
    }
    
    @ViewBuilder
    private func favoriteSwipeButton(for track: AudiobookTrack, in collection: AudiobookCollection) -> some View {
        Button {
            library.toggleFavorite(for: track.id, in: collection.id)
            audioPlayer.notifyFavoriteToggle(for: track.id)
        } label: {
            Label(
                track.isFavorite
                ? NSLocalizedString("remove_from_favorites", comment: "Remove from favorites")
                : NSLocalizedString("add_to_favorites", comment: "Add to favorites"),
                systemImage: track.isFavorite ? "heart.slash" : "heart"
            )
        }
        .labelStyle(.iconOnly)
        .tint(track.isFavorite ? .pink : Color.accentColor)
    }

    private func removePrompt(for track: AudiobookTrack) -> String {
        let template = NSLocalizedString("remove_track_prompt", comment: "Remove track confirmation prompt")
        return template.replacingOccurrences(of: "{{name}}", with: track.displayName)
    }

    private func previousTrack(before track: AudiobookTrack) -> AudiobookTrack? {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return nil
        }
        guard index > sortedTracks.startIndex else {
            return nil
        }
        let previousIndex = sortedTracks.index(before: index)
        return sortedTracks[previousIndex]
    }

    private func nextTrack(after track: AudiobookTrack) -> AudiobookTrack? {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return nil
        }
        let nextIndex = sortedTracks.index(after: index)
        guard sortedTracks.indices.contains(nextIndex) else {
            return nil
        }
        return sortedTracks[nextIndex]
    }

    @State private var transcriptStatusTask: Task<Void, Never>?
    @State private var sttTranscribingTrackIds: Set<UUID> = []
    @State private var ttsGeneratingTrackIds: Set<UUID> = []

    // ... (removed duplicates)

    private func loadTranscriptStatus() {
        guard let collection else { return }

        transcriptStatusTask?.cancel()

        let tracks = isPagedMode ? pagedTracks : collection.tracks
        let trackIds = tracks.map { $0.id }

        transcriptStatusTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            guard !trackIds.isEmpty else {
                await MainActor.run {
                    self.transcriptStatusCache = [:]
                }
                return
            }

            let dbManager = GRDBDatabaseManager.shared

            do {
                let trackIdStrings = trackIds.map { $0.uuidString }
                var completedSet = Set<String>()

                let batchSize = 200
                var index = 0
                while index < trackIdStrings.count {
                    if Task.isCancelled { return }
                    let end = min(index + batchSize, trackIdStrings.count)
                    let batch = Array(trackIdStrings[index..<end])
                    let completedIds = try await dbManager.fetchTrackIdsWithCompletedTranscripts(trackIds: batch)
                    completedSet.formUnion(completedIds)
                    index = end
                }

                if Task.isCancelled { return }

                await MainActor.run {
                    var newCache: [UUID: Bool] = [:]
                    for track in tracks {
                        newCache[track.id] = completedSet.contains(track.id.uuidString)
                    }
                    self.transcriptStatusCache = newCache
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.transcriptStatusCache = [:]
                }
            }
        }
    }

    private func confirmDeleteTranscript(_ track: AudiobookTrack) {
        guard !isEbookCollection else { return }
        trackPendingTranscriptDeletion = track
        showTranscriptDeletionDialog = true
    }

    private func deleteTranscript(for track: AudiobookTrack) {
        showTranscriptDeletionDialog = false
        trackPendingTranscriptDeletion = nil

        Task {
            do {
                try await transcriptionManager.deleteTranscript(forTrackId: track.id)
                await MainActor.run {
                    transcriptStatusCache[track.id] = false
                }
                loadTranscriptStatus()
            } catch {
                await MainActor.run {
                    transcriptDeletionError = error.localizedDescription
                    showTranscriptDeletionError = true
                }
            }
        }
    }

    private func handlePhotosPickerSelection(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CollectionCoverImageStore.CoverError.invalidData
                }
                await applyCoverImageData(data)
            } catch {
                await MainActor.run {
                    coverUpdateError = error.localizedDescription
                    showCoverUpdateError = true
                }
            }
            await MainActor.run {
                coverPhotoItem = nil
            }
        }
    }

    private func handleCoverFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            coverUpdateError = error.localizedDescription
            showCoverUpdateError = true
        case .success(let url):
            Task {
                let needsAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if needsAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let data = try Data(contentsOf: url)
                    await applyCoverImageData(data)
                } catch {
                    await MainActor.run {
                        coverUpdateError = error.localizedDescription
                        showCoverUpdateError = true
                    }
                }
            }
        }
    }

    private func applyCoverImageData(_ data: Data) async {
        await MainActor.run {
            isUpdatingCover = true
        }

        do {
            try await library.updateCollectionCover(collectionID: collectionID, imageData: data)
        } catch {
            await MainActor.run {
                coverUpdateError = error.localizedDescription
                showCoverUpdateError = true
            }
        }

        await MainActor.run {
            isUpdatingCover = false
        }
    }

    private func resetCollectionCoverArtwork() {
        Task {
            await MainActor.run {
                isUpdatingCover = true
            }
            await library.resetCollectionCover(collectionID: collectionID)
            await MainActor.run {
                isUpdatingCover = false
            }
        }
    }

    private func refreshCollectionAction() {
        guard let collection = self.collection else { return }
        
        Task {
            do {
                let candidates: [AudiobookTrack]
                switch collection.source {
                case .baiduNetdisk:
                    guard let token = authViewModel.token else {
                        await MainActor.run {
                            missingAuthAlert = true
                        }
                        return
                    }
                    candidates = try await library.scanNewTracksForBaiduCollection(collectionId: collectionID, token: token)
                case .rss:
                    candidates = try await library.scanNewTracksForRSSCollection(collectionId: collectionID)
                default:
                    return
                }
                
                if !candidates.isEmpty {
                    await MainActor.run {
                        candidateTracks = candidates
                        selectedCandidateIds = Set(candidates.map(\.id))
                        refreshReviewTitle = collection.title
                        refreshReviewDescription = collection.description ?? ""
                        showRefreshReview = true
                    }
                } else {
                    await MainActor.run {
                        refreshResult = NSLocalizedString("refresh_no_updates", value: "No new tracks found.", comment: "Refresh result: no updates")
                        showRefreshResult = true
                    }
                }
            } catch {
                await MainActor.run {
                    refreshResult = String(format: NSLocalizedString("refresh_failed_message", value: "Refresh failed: %@", comment: "Refresh failed message"), error.localizedDescription)
                    showRefreshResult = true
                }
            }
        }
    }

    private func refreshSttTranscribingTrackIds(from jobs: [TranscriptionJob]) {
        let newIds = Set(
            jobs
                .filter { !$0.sonioxJobId.hasPrefix("tts-") }
                .compactMap { UUID(uuidString: $0.trackId) }
        )

        if newIds != sttTranscribingTrackIds {
            sttTranscribingTrackIds = newIds
        }
    }

    private func refreshTTSGeneratingTrackIds(from jobs: [TranscriptionJob]) {
        let generatingStates: Set<String> = ["queued", "downloading", "uploading", "transcribing", "processing", "generating"]
        let newIds = Set(
            jobs
                .filter { generatingStates.contains($0.status) && $0.sonioxJobId.hasPrefix("tts-") }
                .compactMap { UUID(uuidString: $0.trackId) }
        )

        if newIds != ttsGeneratingTrackIds {
            ttsGeneratingTrackIds = newIds
        }
    }

}

private struct CollectionInfoEditorView: View {
    let title: String
    let nameFieldLabel: String
    let descriptionFieldLabel: String
    @Binding var name: String
    @Binding var description: String
    @Binding var isMusic: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var didComplete = false

    private enum Field {
        case name
        case description
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(nameFieldLabel, text: $name)
                        .focused($focusedField, equals: .name)
                        .onAppear {
                            focusedField = .name
                        }
                        .onChange(of: name) { newValue in
                            if newValue.count > 256 {
                                name = String(newValue.prefix(256))
                            }
                        }
                        .textInputAutocapitalization(.words)

                    TextField(descriptionFieldLabel, text: $description, axis: .vertical)
                        .focused($focusedField, equals: .description)
                        .lineLimit(3...6)
                        .onChange(of: description) { newValue in
                            if newValue.count > 1024 {
                                description = String(newValue.prefix(1024))
                            }
                        }
                        .textInputAutocapitalization(.sentences)
                        
                    Toggle("Music Collection", isOn: $isMusic)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", comment: "Cancel button")) {
                        didComplete = true
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("ok_button", comment: "OK button")) {
                        didComplete = true
                        onSubmit()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                didComplete = false
            }
            .onDisappear {
                if !didComplete {
                    onCancel()
                }
            }
        }
    }
}

private struct CollectionDescriptionView: View {
    let description: String
    @Binding var isExpanded: Bool

    private let collapsedLineLimit = 6
    private let toggleThreshold = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .textSelection(.enabled)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .overlay(alignment: .bottom) {
                    if shouldShowToggle && !isExpanded {
                        LinearGradient(
                            gradient: Gradient(
                                colors: [
                                    Color(.systemBackground).opacity(0),
                                    Color(.systemBackground)
                                ]
                            ),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 30)
                        .allowsHitTesting(false)
                    }
                }

            if shouldShowToggle {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            isExpanded ?
                            NSLocalizedString("collection_description_show_less", value: "Show less", comment: "Collapse collection description button") :
                            NSLocalizedString("collection_description_show_more", value: "Show more", comment: "Expand collection description button")
                        )
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded ?
                    NSLocalizedString("collection_description_show_less_accessibility", value: "Show less description", comment: "Accessibility label for collapsing collection description") :
                    NSLocalizedString("collection_description_show_more_accessibility", value: "Show full description", comment: "Accessibility label for expanding collection description")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowToggle: Bool {
        description.count > toggleThreshold
    }
}

private struct RenameEntryView: View {
    let title: String
    let fieldLabel: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusField: Bool
    @State private var didComplete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fieldLabel, text: $text, axis: .vertical)
                        .focused($focusField)
                        .onAppear {
                            focusField = true
                        }
                        .onChange(of: text) { newValue in
                            if newValue.count > 256 {
                                text = String(newValue.prefix(256))
                            }
                        }
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", comment: "Cancel button")) {
                        didComplete = true
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("ok_button", comment: "OK button")) {
                        didComplete = true
                        onSubmit()
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                didComplete = false
            }
            .onDisappear {
                if !didComplete {
                    onCancel()
                }
            }
        }
    }
}

private struct TrackDetailRow: View, Equatable {
    let index: Int
    let track: AudiobookTrack
    let collection: AudiobookCollection
    let isActive: Bool
    let isPlaying: Bool
    let playbackState: TrackPlaybackState?
    let isFavorite: Bool
    let hasTranscript: Bool
    let hasSummary: Bool
    let isTranscribing: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    static func == (lhs: TrackDetailRow, rhs: TrackDetailRow) -> Bool {
        lhs.index == rhs.index &&
        lhs.track.id == rhs.track.id &&
        lhs.collection.id == rhs.collection.id && // Only compare ID, assuming title doesn't change often or doesn't matter for row layout
        lhs.track.displayName == rhs.track.displayName &&
        lhs.track.fileSize == rhs.track.fileSize &&
        lhs.isActive == rhs.isActive &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.playbackState == rhs.playbackState &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.hasTranscript == rhs.hasTranscript &&
        lhs.hasSummary == rhs.hasSummary &&
        lhs.isTranscribing == rhs.isTranscribing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityLabel(track.displayName)

                progressSummaryView

                metadataRow
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                DownloadButton(track: track, collection: collection)

                FavoriteToggleButton(isFavorite: isFavorite) {
                    onToggleFavorite()
                }
                .font(.headline)

                playPauseButton
            }
        }
        .padding(.vertical, 2)
    }

    private var playPauseButton: some View {
        Button(action: onSelect) {
            Group {
                if isActive {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(playPauseAccessibilityLabel))
        .accessibilityHint(Text(NSLocalizedString("play_pause_button_hint", comment: "Accessibility hint for play pause button")))
        .frame(width: 26, height: 26)
    }

    private var playPauseAccessibilityLabel: String {
        if isActive && isPlaying {
            return String(
                format: NSLocalizedString(
                    "pause_track_button_accessibility",
                    comment: "Accessibility label for pause track button"
                ),
                track.displayName
            )
        }

        return String(
            format: NSLocalizedString(
                "play_track_button_accessibility",
                comment: "Accessibility label for play track button"
            ),
            track.displayName
        )
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    // Show character count for text tracks, file size for others
                    if track.isTextTrack, let charCount = track.characterCount {
                        Text("\(formatNumber(charCount)) chars")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(formatBytes(track.fileSize))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if hasTranscript {
                        Image(systemName: "text.alignleft")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .accessibilityLabel(NSLocalizedString("transcript_available", comment: "Transcript available accessibility label"))
                    }

                    if hasSummary {
                        Image(systemName: "text.book.closed")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .accessibilityLabel(NSLocalizedString("track_summary_indicator_label", comment: "Track summary availability indicator"))
                    }

                    if track.isVideoTrack {
                        Image(systemName: "film")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(NSLocalizedString("video_track_indicator_label", value: "Video", comment: "Video track indicator"))
                    }

                    if isTranscribing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                                .progressViewStyle(.circular)
                            Text(NSLocalizedString("transcription_step_transcribing", comment: ""))
                                .font(.caption2)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(Color.blue)
                        .accessibilityLabel(NSLocalizedString("transcription_view_running_job", comment: "View running transcription"))
                    }
                }

                Spacer(minLength: 0)
            }

            if !collection.isMusic, let state = playbackState, state.position > 1 {
                HStack(spacing: 8) {
                    if let duration = state.duration, duration > 0 {
                        let clampedPosition = min(state.position, duration)
                        Text("\(clampedPosition.formattedTimestamp) / \(duration.formattedTimestamp)")
                    } else {
                        Text("Last: \(state.position.formattedTimestamp)")
                    }

                    if let duration = state.duration, duration > 0 {
                        Text(percentString(position: min(state.position, duration), duration: duration))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var progressSummaryView: some View {
        if !collection.isMusic, let state = playbackState, state.position > 1 {
            if let duration = state.duration, duration > 0 {
                let clampedPosition = min(state.position, duration)
                ProgressView(value: clampedPosition, total: duration)
                    .progressViewStyle(.linear)
            } else {
                Text("Last position: \(state.position.formattedTimestamp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let clamped = max(0, min(position / duration, 1))
        let percent = Int(round(clamped * 100))
        return "\(percent)%"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        
        if number >= 1_000_000 {
            let millions = Double(number) / 1_000_000
            return "\(formatter.string(from: NSNumber(value: millions)) ?? "")M"
        } else if number >= 1_000 {
            let thousands = Double(number) / 1_000
            return "\(formatter.string(from: NSNumber(value: thousands)) ?? "")k"
        } else {
            return "\(number)"
        }
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
            .tint(Color.accentColor)

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
