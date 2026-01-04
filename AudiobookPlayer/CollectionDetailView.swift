import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import GRDB

struct CollectionDetailView: View {
    @StateObject private var viewModel: CollectionDetailViewModel

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var tabSelection: TabSelectionManager

    init(collectionID: UUID) {
        _viewModel = StateObject(wrappedValue: CollectionDetailViewModel(collectionID: collectionID))
    }

    var body: some View {
        let baseView = content
            .navigationTitle(viewModel.collection?.title ?? NSLocalizedString("collection_title_fallback", comment: "Collection detail fallback title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $viewModel.searchText,
                prompt: Text(NSLocalizedString("search_tracks_prompt", comment: "Search tracks prompt"))
            )
            .toolbar {
                if library.canModifyCollection(viewModel.collectionID) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            // Hide "Add Tracks" for RSS collections
                            if case .rss = viewModel.collection?.source {
                                // Do not show Add Tracks
                            } else {
                                Button(action: viewModel.addTracksAction) {
                                    Label(
                                        NSLocalizedString("add_tracks_button", comment: "Add tracks button"),
                                        systemImage: "plus.circle"
                                    )
                                }
                            }
                            
                            if viewModel.canRefreshCurrentCollection {
                                Button(action: viewModel.refreshCollectionAction) {
                                    Label(NSLocalizedString("refresh_collection_button", value: "Refresh Collection", comment: "Refresh collection button"), systemImage: "arrow.clockwise")
                                }
                            }
                            
                            Button(action: { viewModel.showBatchRename = true }) {
                                Label("Batch Rename", systemImage: "pencil.and.list.clipboard")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }

        let viewWithAlerts = baseView
            .alert(NSLocalizedString("connect_baidu_first", comment: "Connect Baidu First alert"), isPresented: $viewModel.missingAuthAlert) {
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("sign_in_on_sources_tab", comment: "Sign in on sources tab message"))
            }
            .alert(
                NSLocalizedString("remove_track_action", comment: "Remove track dialog title"),
                isPresented: $viewModel.showDeleteConfirmation,
                presenting: viewModel.trackToDelete
            ) { _ in
                Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) {
                    viewModel.trackToDelete = nil
                }
                Button(NSLocalizedString("remove_track_action", comment: "Remove track action label"), role: .destructive) {
                    viewModel.deleteSelectedTrack()
                }
            } message: { track in
                Text(viewModel.removePrompt(for: track))
            }
            .alert(
                NSLocalizedString("delete_transcript_confirm_title", comment: "Delete transcript dialog title"),
                isPresented: $viewModel.showTranscriptDeletionDialog,
                presenting: viewModel.trackPendingTranscriptDeletion
            ) { track in
                Button(NSLocalizedString("delete_transcript_cancel", comment: "Cancel delete transcript"), role: .cancel) {
                    viewModel.trackPendingTranscriptDeletion = nil
                }
                Button(NSLocalizedString("delete_transcript_confirm", comment: "Confirm delete transcript"), role: .destructive) {
                    viewModel.deleteTranscript(for: track)
                }
            } message: { track in
                Text(String(format: NSLocalizedString("delete_transcript_confirm_message", comment: "Delete transcript confirm message"), track.displayName))
            }
            .alert(
                "Ebook Import Error",
                isPresented: Binding(
                    get: { viewModel.ebookImportError != nil },
                    set: { if !$0 { viewModel.ebookImportError = nil } }
                ),
                presenting: viewModel.ebookImportError
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error)
            }
            .alert(
                NSLocalizedString("error_title", comment: "Generic error title"),
                isPresented: $viewModel.showTranscriptDeletionError,
                presenting: viewModel.transcriptDeletionError
            ) { _ in
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) {
                    viewModel.showTranscriptDeletionError = false
                }
            } message: { error in
                Text(error)
            }
            .alert(
                NSLocalizedString("cover_update_failed_title", comment: "Cover update failed title"),
                isPresented: $viewModel.showCoverUpdateError,
                presenting: viewModel.coverUpdateError
            ) { _ in
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) {
                    viewModel.showCoverUpdateError = false
                }
            } message: { error in
                Text(error)
            }
            .overlay {
                if viewModel.isRefreshingCollection {
                    ProgressView("Refreshing...")
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
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
                    if let track = audioPlayer.trackToGenerateAudio, let collection = viewModel.collection {
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
                isPresented: $viewModel.showRefreshResult,
                presenting: viewModel.refreshResult
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { result in
                Text(result)
            }

        let viewWithSheets = viewWithAlerts
            .fullScreenCover(isPresented: $viewModel.showTrackPicker) {
                TrackPickerView(
                    collectionID: viewModel.collectionID,
                    onTracksSelected: { newTracks in
                        library.addTracksToCollection(
                            collectionID: viewModel.collectionID,
                            newTracks: newTracks
                        )
                    }
                )
                .environmentObject(library)
                .environmentObject(authViewModel)
            }
            .sheet(item: $viewModel.trackToRename) { track in
                RenameEntryView(
                    title: NSLocalizedString("rename_track_title", comment: "Rename track title"),
                    fieldLabel: NSLocalizedString("name_field_label", comment: "Name field label"),
                    text: $viewModel.trackTitleDraft,
                    onSubmit: {
                        viewModel.applyTrackRename(for: track)
                    },
                    onCancel: viewModel.cancelTrackRename
                )
            }
            .sheet(isPresented: $viewModel.showCollectionInfoSheet) {
                CollectionInfoEditorView(
                    title: NSLocalizedString("edit_collection_details_title", comment: "Edit collection details title"),
                    nameFieldLabel: NSLocalizedString("name_field_label", comment: "Name field label"),
                    descriptionFieldLabel: NSLocalizedString("collection_description_field_label", comment: "Collection description field label"),
                    name: $viewModel.collectionTitleDraft,
                    description: $viewModel.collectionDescriptionDraft,
                    isMusic: $viewModel.collectionIsMusicDraft,
                    folderPath: $viewModel.collectionFolderPathDraft,
                    onSubmit: viewModel.applyCollectionDetailsUpdate,
                    onCancel: viewModel.cancelCollectionDetailsEdit
                )
            }
            .sheet(item: $viewModel.trackForTranscription) { track in
                TranscriptionSheet(
                    track: track,
                    collectionID: viewModel.collectionID,
                    collectionTitle: viewModel.collection?.title ?? "",
                    collectionDescription: viewModel.collection?.description
                )
            }
            .sheet(item: $viewModel.trackForTTSProgress) { track in
                TTSJobProgressSheet(track: track)
            }
            .sheet(item: $viewModel.trackForViewing) { track in
                TranscriptViewerSheet(trackId: track.id.uuidString, trackName: track.displayName, showTrackSummary: true)
            }
            .sheet(item: $viewModel.trackForDetails) { track in
                TrackDetailsSheetView(track: track, collection: viewModel.collection)
            }
            .sheet(item: $viewModel.trackForChat) { track in
                TrackChatSheetWrapper(trackId: track.id.uuidString, collectionId: viewModel.collectionID.uuidString)
            }
            .sheet(item: $viewModel.trackForReading) { track in
                if let collection = viewModel.collection {
                    NavigationStack {
                        EbookReaderView(track: track, collection: collection)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showBatchRename) {
                if let collection = viewModel.collection {
                    BatchRenameView(
                        tracks: collection.tracks,
                        onApply: { changes in
                            library.batchRenameTracks(in: viewModel.collectionID, changes: changes)
                            viewModel.showBatchRename = false
                        },
                        onCancel: {
                            viewModel.showBatchRename = false
                        }
                    )
                }
            }
            .sheet(isPresented: $viewModel.showCoverPhotosPicker) {
                CoverPhotoCropPicker(isPresented: $viewModel.showCoverPhotosPicker) { image in
                    viewModel.handleCroppedCoverImage(image)
                }
            }
            .fileImporter(isPresented: $viewModel.showCoverFileImporter, allowedContentTypes: [.image]) { result in
                viewModel.handleCoverFileImport(result)
            }
            .navigationDestination(isPresented: $viewModel.showRefreshReview) {
                CollectionRefreshReviewView(
                    title: $viewModel.refreshReviewTitle,
                    description: $viewModel.refreshReviewDescription,
                    candidateTracks: viewModel.candidateTracks,
                    selectedCandidateIds: $viewModel.selectedCandidateIds,
                    onSave: {
                        let selected = viewModel.candidateTracks.filter { viewModel.selectedCandidateIds.contains($0.id) }
                        library.addTracks(to: viewModel.collectionID, tracks: selected)

                        if let collection = viewModel.collection, (viewModel.refreshReviewTitle != collection.title || viewModel.refreshReviewDescription != (collection.description ?? "")) {
                            library.updateCollectionDetails(
                                collectionID: viewModel.collectionID,
                                newTitle: viewModel.refreshReviewTitle,
                                newDescription: viewModel.refreshReviewDescription.isEmpty ? nil : viewModel.refreshReviewDescription,
                                shouldUpdateDescription: true
                            )
                        }

                        viewModel.showRefreshReview = false
                        viewModel.refreshResult = String(format: NSLocalizedString("refresh_success_message", value: "Added %d tracks.", comment: "Refresh success"), selected.count)
                        viewModel.showRefreshResult = true
                    },
                    onCancel: {
                        viewModel.showRefreshReview = false
                    }
                )
            }

        let viewWithPlaybackEvents = viewWithSheets
            .onChange(of: audioPlayer.currentTrack?.id) { _, _ in
                let currentCollection = viewModel.collection

                if
                    audioPlayer.activeCollection?.id == viewModel.collectionID,
                    let collection = currentCollection,
                    let track = audioPlayer.currentTrack
                {
                    // Always record when track changes
                    viewModel.recordPlayback(for: collection, track: track, position: audioPlayer.currentTime)
                }

                viewModel.prepareAutoFocusTargetIfNeeded(for: currentCollection)
            }
            .background(CollectionPlaybackProgressObserver(collectionID: viewModel.collectionID))

        let viewWithStateEvents = viewWithPlaybackEvents
            .onChange(of: viewModel.trackToRename) { _, newValue in
                if newValue == nil {
                    viewModel.trackTitleDraft = ""
                }
            }
            .onChange(of: viewModel.showCollectionInfoSheet) { _, newValue in
                if !newValue {
                    viewModel.collectionTitleDraft = ""
                    viewModel.collectionDescriptionDraft = ""
                }
            }
            .onChange(of: viewModel.collectionID) {
                viewModel.resetAutoFocusState()
                viewModel.loadTranscriptStatus()
                viewModel.prepareAutoFocusTargetIfNeeded(for: viewModel.collection)
                viewModel.refreshTrackSummaryIndicators(for: viewModel.collection)
                viewModel.refreshPlaybackStateSnapshot(for: viewModel.collection)

                // Restore saved sort preference or apply smart defaults
                if let collection = viewModel.collection {
                    if let savedSortOrder = collection.preferredSortOrder {
                        // Try to parse new format: "criterion:order"
                        let components = savedSortOrder.split(separator: ":")
                        if components.count == 2,
                           let criterion = CollectionDetailViewModel.SortCriterion(rawValue: String(components[0])),
                           let order = CollectionDetailViewModel.SortOrder(rawValue: String(components[1])) {
                            viewModel.selectedCriterion = criterion
                            viewModel.selectedOrder = order
                        } else {
                            // Apply smart defaults based on collection source
                            if case .rss = collection.source {
                                // RSS collections default to newest-first (descending track number)
                                viewModel.selectedCriterion = .trackNumber
                                viewModel.selectedOrder = .descending
                            } else {
                                // Other collections default to oldest-first (ascending track number)
                                viewModel.selectedCriterion = .trackNumber
                                viewModel.selectedOrder = .ascending
                            }
                        }
                    } else {
                        // Apply smart defaults based on collection source
                        if case .rss = collection.source {
                            // RSS collections default to newest-first (descending track number)
                            viewModel.selectedCriterion = .trackNumber
                            viewModel.selectedOrder = .descending
                        } else {
                            // Other collections default to oldest-first (ascending track number)
                            viewModel.selectedCriterion = .trackNumber
                            viewModel.selectedOrder = .ascending
                        }
                    }
                }
            }
            .onChange(of: viewModel.collection?.tracks.map(\.id) ?? []) {
                viewModel.prepareAutoFocusTargetIfNeeded(for: viewModel.collection)
                viewModel.refreshTrackSummaryIndicators(for: viewModel.collection)
                viewModel.refreshPlaybackStateSnapshot(for: viewModel.collection)
            }
            .onChange(of: audioPlayer.activeCollection?.id) {
                viewModel.prepareAutoFocusTargetIfNeeded(for: viewModel.collection)
            }

        return viewWithStateEvents
            .onAppear {
                viewModel.setup(
                    library: library,
                    audioPlayer: audioPlayer,
                    authViewModel: authViewModel,
                    transcriptionManager: transcriptionManager,
                    aiGenerationManager: aiGenerationManager
                )
                
                viewModel.refreshSttTranscribingTrackIds(from: transcriptionManager.activeJobs)
                viewModel.refreshTTSGeneratingTrackIds(from: transcriptionManager.activeJobs)

                viewModel.loadTranscriptStatus()
                viewModel.prepareAutoFocusTargetIfNeeded(for: viewModel.collection)
                viewModel.refreshTrackSummaryIndicators(for: viewModel.collection)
                viewModel.refreshPlaybackStateSnapshot(for: viewModel.collection)
                
                // Trigger lazy load
                Task {
                    await library.ensureCollectionLoaded(viewModel.collectionID)
                    await MainActor.run {
                        viewModel.refreshPlaybackStateSnapshot(for: viewModel.collection)
                        viewModel.currentQuery = viewModel.searchText
                        viewModel.currentFilterKey = viewModel.selectedFilter
                        viewModel.currentSortCriterion = viewModel.selectedCriterion
                        viewModel.currentSortOrder = viewModel.selectedOrder
                    }
                    await viewModel.reloadFromDatabase(startingPage: 0, focusTarget: viewModel.pendingAutoFocusTrackId)
                }
            }
            .onChange(of: viewModel.collection?.tracks) { viewModel.scheduleSortedTracksUpdate() }
            .onChange(of: viewModel.searchText) {
                // Debounce search to avoid hammering DB per keystroke
                viewModel.searchDebounceTask?.cancel()
                viewModel.searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run { viewModel.scheduleFilteredTracksUpdate() }
                }
            }
            .onSubmit(of: .search) {
                viewModel.searchDebounceTask?.cancel()
                viewModel.scheduleFilteredTracksUpdate()
            }
            .onChange(of: viewModel.selectedFilter) { viewModel.scheduleFilteredTracksUpdate() }
            .onChange(of: viewModel.selectedCriterion) {
                viewModel.scheduleSortedTracksUpdate()
                // Persist sort preference to collection
                if let collection = viewModel.collection {
                    let sortString = "\(viewModel.selectedCriterion.rawValue):\(viewModel.selectedOrder.rawValue)"
                    library.updatePreferredSortOrder(sortString, for: collection.id)
                }
            }
            .onChange(of: viewModel.selectedOrder) {
                viewModel.scheduleSortedTracksUpdate()
                // Persist sort preference to collection
                if let collection = viewModel.collection {
                    let sortString = "\(viewModel.selectedCriterion.rawValue):\(viewModel.selectedOrder.rawValue)"
                    library.updatePreferredSortOrder(sortString, for: collection.id)
                }
            }
            .onChange(of: viewModel.transcriptStatusCache) { viewModel.scheduleFilteredTracksUpdate() }
            .onChange(of: viewModel.tracksWithSummaries) { viewModel.scheduleFilteredTracksUpdate() }
            .onReceive(transcriptionManager.$activeJobs) { jobs in
                viewModel.refreshSttTranscribingTrackIds(from: jobs)
                viewModel.refreshTTSGeneratingTrackIds(from: jobs)
            }
            .onChange(of: aiGenerationManager.activeJobs) { jobs in
                guard jobs.contains(where: { $0.type == .trackSummary }) else { return }
                viewModel.refreshTrackSummaryIndicators(for: viewModel.collection)
            }
            .onChange(of: aiGenerationManager.recentJobs) { jobs in
                guard jobs.contains(where: { $0.type == .trackSummary }) else { return }
                viewModel.refreshTrackSummaryIndicators(for: viewModel.collection)
            }
            .onDisappear {
                viewModel.summaryIndicatorTask?.cancel()
                viewModel.summaryIndicatorTask = nil
                viewModel.filterTask?.cancel()
                viewModel.sortTask?.cancel()
                viewModel.cachedOrderedTracks = []
                viewModel.cachedSortedTracks = []
                viewModel.transcriptStatusCache = [:]
                viewModel.tracksWithSummaries = []
                viewModel.playbackStateSnapshot = [:]
                viewModel.loadedPages = [:]
                viewModel.loadingPages = []
                viewModel.totalPages = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { notification in
                AppLog.debug("[CollectionDetailView] Received TranscriptionCompleted notification")
                // Reload transcript status when a transcription completes
                viewModel.loadTranscriptStatus()
            }
            .fileImporter(
                isPresented: $viewModel.showEbookFileImporter,
                allowedContentTypes: [UTType.epub],
                allowsMultipleSelection: false
            ) { result in
                AppLog.debug("[CollectionDetailView] File importer completed")
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        viewModel.handleEbookFileImport(.success(url))
                    } else {
                        AppLog.debug("[CollectionDetailView] No file selected")
                    }
                case .failure(let error):
                    viewModel.handleEbookFileImport(.failure(error))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let collection = viewModel.collection {
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
                    viewModel.prepareAutoFocusTargetIfNeeded(for: collection)
                    attemptAutoFocusIfNeeded(using: proxy)
                }
                .onChange(of: viewModel.pendingAutoFocusTrackId) {
                    attemptAutoFocusIfNeeded(using: proxy)
                }
                .onChange(of: viewModel.filteredTracks.map(\.id)) {
                    attemptAutoFocusIfNeeded(using: proxy)
                    viewModel.isLastTrackVisible = false
                }
                .onChange(of: viewModel.isListLoading) { loading in
                    // When loading finishes, try auto-focus since data is now ready
                    if !loading {
                        attemptAutoFocusIfNeeded(using: proxy)
                    }
                }
                
                // Jump to Top/Bottom Buttons (Centered)
                if viewModel.filteredTracks.count > 10 && (viewModel.showScrollToTopButton || viewModel.showScrollToBottomButton) {
                    VStack {
                        if viewModel.showScrollToTopButton {
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
                        
                        if viewModel.showScrollToBottomButton {
                            Button {
                                if viewModel.isPagedMode {
                                    let maxLoaded = viewModel.loadedPages.keys.max() ?? 0
                                    let nextPage = maxLoaded + 1
                                    if nextPage < viewModel.totalPages {
                                        Task {
                                            await viewModel.loadPage(nextPage)
                                            await MainActor.run {
                                                if let last = viewModel.filteredTracks.last {
                                                    withAnimation {
                                                        proxy.scrollTo(last.id, anchor: .bottom)
                                                    }
                                                }
                                            }
                                        }
                                        return
                                    }
                                }
                                
                                if let last = viewModel.filteredTracks.last {
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
                        inlineCollectionTitle(for: collection)
                            .font(.title3)
                            .bold()
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

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

                        if collection.description?.isEmpty != false, library.canModifyCollection(viewModel.collectionID) {
                            Button {
                                viewModel.beginEditingCollectionDetails(collection)
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

                    if library.canModifyCollection(viewModel.collectionID) {
                        Menu {
                            Button {
                                viewModel.beginEditingCollectionDetails(collection)
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
                        isExpanded: $viewModel.isDescriptionExpanded
                    )
                } else {
                    Text(NSLocalizedString("collection_description_empty", comment: "Collection description empty placeholder"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: collection.id) {
            viewModel.isDescriptionExpanded = false
        }
        .onChange(of: collection.description ?? "") {
            viewModel.isDescriptionExpanded = false
        }
        .onAppear {
            viewModel.isSummaryVisible = true
        }
        .onDisappear {
            viewModel.isSummaryVisible = false
        }
    }
    
    private func inlineCollectionTitle(for collection: AudiobookCollection) -> Text {
        let titleText = Text(collection.title)

        if case .ebook = collection.source {
            return coloredIconText("book", color: .blue) + Text(" ") + titleText
        } else if case .rss = collection.source {
            return coloredIconText("antenna.radiowaves.left.and.right", color: .orange) + Text(" ") + titleText
        } else if collection.isMusic {
            return coloredIconText("music.note", color: .pink) + Text(" ") + titleText
        }

        return titleText
    }

    private func coloredIconText(_ systemName: String, color: Color) -> Text {
        Text(Image(systemName: systemName)).foregroundStyle(color)
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

            // Filter menu
            Menu {
                ForEach(CollectionDetailViewModel.FilterOption.allCases) { option in
                    Button {
                        viewModel.selectedFilter = option
                    } label: {
                        if viewModel.selectedFilter == option {
                            Label(option.localizedName, systemImage: "checkmark")
                        } else {
                            Label(option.localizedName, systemImage: option.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: viewModel.selectedFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.selectedFilter == .all ? .secondary : Color.accentColor)
            }

            // Sort menu
            Menu {
                Section {
                    ForEach(CollectionDetailViewModel.SortCriterion.allCases) { criterion in
                        Button {
                            viewModel.selectedCriterion = criterion
                        } label: {
                            if viewModel.selectedCriterion == criterion {
                                Label(criterion.localizedName, systemImage: "checkmark")
                            } else {
                                Label(criterion.localizedName, systemImage: criterion.icon)
                            }
                        }
                    }
                } header: {
                    Text("Sort By")
                }

                Section {
                    ForEach(CollectionDetailViewModel.SortOrder.allCases) { order in
                        Button {
                            viewModel.selectedOrder = order
                        } label: {
                            if viewModel.selectedOrder == order {
                                Label(order.localizedName, systemImage: "checkmark")
                            } else {
                                Label(order.localizedName, systemImage: order.icon)
                            }
                        }
                    }
                } header: {
                    Text("Order")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

            if viewModel.isUpdatingCover {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if library.canModifyCollection(viewModel.collectionID) {
                coverMenu(for: collection)
            }
        }
    }

    private func coverMenu(for collection: AudiobookCollection) -> some View {
        Menu {
            Button {
                viewModel.showCoverPhotosPicker = true
            } label: {
                Label(
                    NSLocalizedString("collection_cover_choose_photo", comment: "Choose cover from photos"),
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            Button {
                viewModel.showCoverFileImporter = true
            } label: {
                Label(
                    NSLocalizedString("collection_cover_import_files", comment: "Import cover from files"),
                    systemImage: "folder.badge.plus"
                )
            }
            if case .image = collection.coverAsset.kind {
                Button(role: .destructive) {
                    viewModel.resetCollectionCoverArtwork()
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
        .disabled(viewModel.isUpdatingCover)
        .accessibilityLabel(Text(NSLocalizedString("collection_cover_edit_accessibility", comment: "Edit cover accessibility label")))
    }

    @ViewBuilder
    private func tracksSection(_ collection: AudiobookCollection) -> some View {
        let tracks = viewModel.filteredTracks
        Section(header: tracksHeader) {
            if tracks.isEmpty {
                if viewModel.isListLoading || (collection.tracks.isEmpty && collection.trackCount > 0) {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                } else {
                    Text(viewModel.searchText.isEmpty ? NSLocalizedString("no_audio_tracks", comment: "No audio tracks") : String(format: NSLocalizedString("no_search_results", comment: "No search results"), viewModel.searchText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    let trackIsActive = viewModel.isCurrentTrack(track: track)
                    let hasTranscript = viewModel.transcriptStatusCache[track.id] ?? false
                    let isTranscribingTrack = viewModel.sttTranscribingTrackIds.contains(track.id)

                    TrackDetailRow(
                        index: index,
                        track: track,
                        collection: collection,
                        isActive: trackIsActive,
                        isPlaying: trackIsActive && audioPlayer.isPlaying,
                        playbackState: viewModel.playbackStateSnapshot[track.id],
                        isFavorite: track.isFavorite,
                        hasTranscript: hasTranscript,
                        hasSummary: viewModel.tracksWithSummaries.contains(track.id),
                        isTranscribing: isTranscribingTrack,
                        onSelect: {
                            viewModel.startPlayback(track, in: collection)
                            tabSelection.switchToPlayingTab()
                        },
                        onToggleFavorite: {
                            library.toggleFavorite(for: track.id, in: collection.id)
                            audioPlayer.notifyFavoriteToggle(for: track.id)
                        }
                    )
                    .equatable()
                    .onAppear {
                        if index == tracks.count - 1 {
                            viewModel.isLastTrackVisible = true
                            // Load next page when bottom is reached in paged mode
                            if viewModel.isPagedMode {
                                let currentPage = viewModel.loadedPages.keys.sorted().last ?? 0
                                Task { await viewModel.loadPage(currentPage + 1) }
                            }
                        }
                    }
                    .onDisappear {
                        if index == tracks.count - 1 {
                            viewModel.isLastTrackVisible = false
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        favoriteSwipeButton(for: track, in: collection)
                    }
                    .swipeActions(edge: .trailing) {
                        if library.canModifyCollection(viewModel.collectionID) {
                            Button {
                                viewModel.beginRenamingTrack(track)
                            } label: {
                                Label(
                                    NSLocalizedString("rename_action", comment: "Rename action"),
                                    systemImage: "pencil"
                                )
                            }
                            .labelStyle(.iconOnly)

                            Button(role: .destructive) {
                                viewModel.confirmDeleteTrack(track)
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
                        Button {
                            viewModel.trackForDetails = track
                        } label: {
                            Label("Track Details", systemImage: "info.circle")
                        }

                        Button {
                            viewModel.trackForChat = track
                        } label: {
                            Label("Chat about this track", systemImage: "bubble.left.and.text.bubble.right")
                        }

                        // Add Read option for text tracks
                        if case .text = track.location {
                            Button {
                                viewModel.trackForReading = track
                            } label: {
                                Label("Read", systemImage: "book")
                            }

                            if viewModel.ttsGeneratingTrackIds.contains(track.id) {
                                Button {
                                    viewModel.trackForTTSProgress = track
                                } label: {
                                    Label("View TTS progress", systemImage: "waveform.path.ecg")
                                }
                            } else {
                                Button {
                                    viewModel.trackForTTSProgress = track
                                    Task {
                                        await audioPlayer.generateAudio(for: track, in: collection)
                                    }
                                } label: {
                                    Label(NSLocalizedString("generate_audio_action", value: "Generate Audio", comment: "Generate audio action"), systemImage: "waveform.badge.plus")
                                }
                            }
                        } else if case .cachedText = track.location {
                            Button {
                                viewModel.trackForReading = track
                            } label: {
                                Label("Read", systemImage: "book")
                            }
                            // Already generated, maybe offer re-generate?
                        }

                        if isTranscribingTrack {
                            Button {
                                viewModel.trackForTranscription = track
                            } label: {
                                Label(
                                    NSLocalizedString("transcription_view_running_job", comment: "View running transcription"),
                                    systemImage: "waveform.badge.exclamationmark"
                                )
                            }
                        } else if !hasTranscript && !track.isTextTrack { // Hide transcribe for text tracks
                            Button {
                                viewModel.trackForTranscription = track
                            } label: {
                                Label(
                                    NSLocalizedString("transcribe_track_title", comment: "Transcribe track title"),
                                    systemImage: "waveform"
                                )
                            }
                        }

                        if hasTranscript {
                            Button {
                                viewModel.trackForViewing = track
                            } label: {
                                Label(
                                    NSLocalizedString("view_transcript", comment: "View transcript menu item"),
                                    systemImage: "text.alignleft"
                                )
                            }

                            if library.canModifyCollection(viewModel.collectionID) && !viewModel.isEbookCollection {
                                Button(role: .destructive) {
                                    viewModel.confirmDeleteTranscript(track)
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
    
    private func attemptAutoFocusIfNeeded(using proxy: ScrollViewProxy?) {
        guard
            !viewModel.didAutoFocusTrack,
            let targetId = viewModel.pendingAutoFocusTrackId,
            viewModel.filteredTracks.contains(where: { $0.id == targetId }),
            !viewModel.isPagedMode, // disable autofocus for large/paged collections
            !viewModel.isListLoading,
            viewModel.loadingPages.isEmpty
        else { return }

        // If proxy is nil, skip this attempt - the onChange handlers will retry with a real proxy
        guard let proxy else { return }

        // Mark as focused immediately to avoid multiple rapid scrolls
        viewModel.didAutoFocusTrack = true

        // Delay to allow ScrollViewReader to register the target ID in its coordinate space
        // Without this delay, scrollTo() may fail because the ID isn't yet in the scroll view's registry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
            viewModel.pendingAutoFocusTrackId = nil
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

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct CollectionInfoEditorView: View {
    let title: String
    let nameFieldLabel: String
    let descriptionFieldLabel: String
    @Binding var name: String
    @Binding var description: String
    @Binding var isMusic: Bool
    @Binding var folderPath: String?
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var didComplete = false
    @State private var localFolderPath: String = ""

    private enum Field {
        case name
        case description
        case folderPath
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

                if folderPath != nil {
                    Section {
                        TextField(
                            NSLocalizedString("folder_path_field_label", comment: "Folder path field label"),
                            text: $localFolderPath
                        )
                        .focused($focusedField, equals: .folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    } header: {
                        Text(NSLocalizedString("baidu_netdisk_source_header", comment: "Baidu Netdisk Source"))
                    } footer: {
                        Text(NSLocalizedString("folder_path_footer", comment: "The folder path in Baidu Netdisk used for refreshing."))
                    }
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
                        // Sync local folder path back to binding before submit
                        if folderPath != nil {
                            folderPath = localFolderPath.isEmpty ? nil : localFolderPath
                        }
                        onSubmit()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                didComplete = false
                // Initialize local folder path from binding
                if let path = folderPath {
                    localFolderPath = path
                }
            }
            .onDisappear {
                if !didComplete {
                    onCancel()
                }
            }
        }
    }
}

private struct TrackDetailsSheetView: View {
    let track: AudiobookTrack
    let collection: AudiobookCollection?

    @StateObject private var summaryViewModel = TrackSummaryViewModel()
    @State private var isTranscriptAvailable = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    Text(track.displayName)
                        .textSelection(.enabled)
                }

                if let sourcePath = sourcePathText(for: track) {
                    Section("Source Path") {
                        Text(sourcePath)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }

                Section("Description") {
                    if let description = trackDescription(for: track) {
                        Text(description)
                            .textSelection(.enabled)
                    } else {
                        Text("No description")
                            .foregroundStyle(.secondary)
                    }
                }

                TrackSummaryCard(
                    track: track,
                    isTranscriptAvailable: isTranscriptAvailable,
                    viewModel: summaryViewModel,
                    seekAndPlayAction: { _ in },
                    onRequestTranscription: nil,
                    onRequestTranslations: nil,
                    isReadOnly: true
                )
            }
            .navigationTitle("Track Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                summaryViewModel.setTrackId(track.id.uuidString)
                Task { await refreshTranscriptAvailability(for: track.id) }
            }
            .onChange(of: track.id) { _, _ in
                summaryViewModel.setTrackId(track.id.uuidString)
                Task { await refreshTranscriptAvailability(for: track.id) }
            }
        }
    }

    private func trackDescription(for track: AudiobookTrack) -> String? {
        let trimmed = track.metadata["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private func sourcePathText(for track: AudiobookTrack) -> String? {
        switch track.location {
        case let .baidu(_, path):
            return path
        case let .external(url):
            return url.absoluteString
        case let .local(bookmark):
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.path
            }
            return nil
        case .text, .cachedText:
            return nil
        }
    }

    @MainActor
    private func refreshTranscriptAvailability(for trackId: UUID) async {
        let transcript = try? await GRDBDatabaseManager.shared.loadTranscript(forTrackId: trackId.uuidString)
        isTranscriptAvailable = transcript != nil
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
                    // Show pubDate for RSS tracks first
                    if let pubDateString = track.metadata["pubDate"], case .rss = collection.source {
                        if let formattedDate = formatPubDate(pubDateString) {
                            Text(formattedDate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

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

    private func formatPubDate(_ isoString: String) -> String? {
        guard let date = CollectionDetailViewModel.parsePubDate(from: isoString) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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

private struct CollectionPlaybackProgressObserver: View {
    @EnvironmentObject private var playbackClock: PlaybackClock
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore

    let collectionID: UUID

    var body: some View {
        Color.clear
            .onChange(of: playbackClock.currentTime) { newValue in
                guard
                    audioPlayer.activeCollection?.id == collectionID,
                    let track = audioPlayer.currentTrack,
                    let collection = library.collections.first(where: { $0.id == collectionID })
                else { return }

                // Approximate 5s checkpoints (matches previous behavior).
                if Int(newValue) % 5 == 0 {
                    library.recordPlaybackProgress(
                        collectionID: collection.id,
                        trackID: track.id,
                        position: newValue,
                        duration: audioPlayer.duration
                    )
                }
            }
    }
}

private struct PlaybackTimeline: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var playbackClock: PlaybackClock

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playbackClock.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...(max(playbackClock.duration, 1))
            )
            .tint(Color.accentColor)

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
