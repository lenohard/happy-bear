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
    @State private var trackForTranscription: AudiobookTrack?
    @State private var trackForViewing: AudiobookTrack?
    @State private var trackForReading: AudiobookTrack?
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
    @State private var scrubberThumbOffset: CGFloat = 0
    @State private var isDraggingScrubber = false

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

    private var sortedTracks: [AudiobookTrack] {
        guard let collection else { return [] }
        
        let tracks = collection.tracks
        
        switch selectedSort {
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

    private var filteredTracks: [AudiobookTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var tracks = sortedTracks
        
        // Apply Filter
        if selectedFilter != .all {
            tracks = tracks.filter { track in
                switch selectedFilter {
                case .all:
                    return true
                case .transcribed:
                    return transcriptStatusCache[track.id] == true
                case .unplayed:
                    let state = collection?.playbackState(for: track.id)
                    return state == nil || state!.position < 1 // Consider < 1 second as unplayed
                case .summarized:
                    return tracksWithSummaries.contains(track.id)
                case .played:
                    if let state = collection?.playbackState(for: track.id) {
                        return state.position >= 1
                    }
                    return false
                }
            }
        }

        guard !query.isEmpty else { return tracks }

        return tracks.filter { track in
            track.displayName.localizedCaseInsensitiveContains(query) ||
            track.filename.localizedCaseInsensitiveContains(query)
        }
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
            }
            .onChange(of: collection?.tracks.map(\.id) ?? []) { _ in
                prepareAutoFocusTargetIfNeeded(for: self.collection)
                refreshTrackSummaryIndicators(for: self.collection)
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
                // Initialize transcribing IDs
                transcribingTrackIds = Set(transcriptionManager.activeJobs.compactMap { UUID(uuidString: $0.trackId) })
                
                loadTranscriptStatus()
                prepareAutoFocusTargetIfNeeded(for: self.collection)
                refreshTrackSummaryIndicators(for: self.collection)
            }
            .onChange(of: aiGenerationManager.activeJobs) { jobs in
                // Optimize: Update the set of transcribing IDs once, instead of filtering in every row
                let newIds = Set(jobs.compactMap { job in job.trackId.flatMap(UUID.init) })
                if newIds != transcribingTrackIds {
                    transcribingTrackIds = newIds
                }
                
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
            ZStack(alignment: .trailing) {
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
                }
                
                // Scroll Scrubber - iOS Style
                if filteredTracks.count > 10 {
                    ScrollScrubberView(
                        trackCount: filteredTracks.count,
                        thumbOffset: $scrubberThumbOffset,
                        isDragging: $isDraggingScrubber,
                        onScroll: { progress in
                            let targetIndex = Int(Double(filteredTracks.count - 1) * progress)
                            if targetIndex >= 0 && targetIndex < filteredTracks.count {
                                let track = filteredTracks[targetIndex]
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(track.id, anchor: .center)
                                }
                            }
                        }
                    )
                    .frame(width: 40)
                    .padding(.trailing, 4)
                }
            }
        }
    }
    
    // MARK: - Scroll Scrubber Component
    private struct ScrollScrubberView: View {
        let trackCount: Int
        @Binding var thumbOffset: CGFloat
        @Binding var isDragging: Bool
        let onScroll: (Double) -> Void
        
        private let trackWidth: CGFloat = 3
        private let thumbWidth: CGFloat = 20
        private let thumbHeight: CGFloat = 40
        
        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    // Track
                    Capsule()
                        .fill(Color.secondary.opacity(isDragging ? 0.2 : 0.1))
                        .frame(width: trackWidth)
                        .frame(maxHeight: .infinity)
                    
                    // Thumb
                    Capsule()
                        .fill(Color.secondary.opacity(isDragging ? 0.8 : 0.5))
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(y: thumbOffset)
                        .animation(.easeOut(duration: 0.1), value: thumbOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            
                            let maxOffset = geometry.size.height - thumbHeight
                            let newOffset = max(0, min(maxOffset, value.location.y - thumbHeight / 2))
                            thumbOffset = newOffset
                            
                            let progress = maxOffset > 0 ? Double(newOffset / maxOffset) : 0
                            onScroll(progress)
                            
                            // Haptic feedback (throttled)
                            if Int(newOffset) % 20 == 0 {
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ collection: AudiobookCollection) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                coverEditor(for: collection)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(collection.title)
                            .font(.title3)
                            .bold()
                        if case .ebook = collection.source {
                            Image(systemName: "book")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .accessibilityLabel(NSLocalizedString("ebook_collection_indicator_accessibility", comment: "Indicator for ebook collection"))
                        }
                    }

                    if let description = collection.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if library.canModifyCollection(collectionID) {
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
                    } else {
                        Text(NSLocalizedString("collection_description_empty", comment: "Collection description empty placeholder"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if case .ebook = collection.source, let charCount = collection.totalCharacterCount {
                         Text("\(collection.tracks.count) tracks • \(formatNumber(charCount)) chars")
                             .font(.caption)
                             .foregroundStyle(.secondary)
                    } else {
                        let totalSize = collection.tracks.reduce(into: Int64(0)) { $0 += $1.fileSize }
                        Text(String(format: NSLocalizedString("track_count_and_size", comment: "Track count and size"), collection.tracks.count, formatBytes(totalSize)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
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
            }
            .padding(.vertical, 4)
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
                    .padding(6)
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
        Section(header: tracksHeader) {
            if filteredTracks.isEmpty {
                Text(searchText.isEmpty ? NSLocalizedString("no_audio_tracks", comment: "No audio tracks") : String(format: NSLocalizedString("no_search_results", comment: "No search results"), searchText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                    let trackIsActive = isCurrentTrack(track: track)
                    let hasTranscript = transcriptStatusCache[track.id] ?? false
                    // Optimized O(1) lookup
                    let isTranscribingTrack = transcribingTrackIds.contains(track.id)

                    TrackDetailRow(
                        index: index,
                        track: track,
                        isActive: trackIsActive,
                        isPlaying: trackIsActive && audioPlayer.isPlaying,
                        playbackState: collection.playbackState(for: track.id),
                        isFavorite: track.isFavorite,
                        hasTranscript: hasTranscript,
                        hasSummary: tracksWithSummaries.contains(track.id),
                        isTranscribing: isTranscribingTrack,
                        onSelect: {
                            startPlayback(track, in: collection)
                        },
                        onToggleFavorite: {
                            library.toggleFavorite(for: track.id, in: collection.id)
                        }
                    )
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

                            Button(role: .destructive) {
                                confirmDeleteTrack(track)
                            } label: {
                                Label(
                                    NSLocalizedString("remove_track_action", comment: "Remove track swipe action"),
                                    systemImage: "trash"
                                )
                            }
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
                            
                            Button {
                                // Trigger manual audio generation
                                Task {
                                    // We need to trigger this via AudioPlayerViewModel or a new method
                                    // For now, let's just play it, which triggers generation if not cached
                                    // But the requirement is to have a specific "Generate Audio" action
                                    // So we might need to expose `playTextTrack` logic or similar without auto-playing,
                                    // or just rely on the fact that playing generates it.
                                    // However, the requirement says "Manual Generate Audio option".
                                    // Let's add a method to AudioPlayerViewModel to generate without playing immediately, or just use play.
                                    // Actually, the plan says: "Add a manual 'Generate Audio' option... When clicking play... pop up confirmation".
                                    // So here we just want to trigger generation.
                                    // I'll add `generateAudio(for: track)` to AudioPlayerViewModel later.
                                    // For now, I'll put a placeholder or call a method I'll add.
                                    await audioPlayer.generateAudio(for: track, in: collection)
                                }
                            } label: {
                                Label(NSLocalizedString("generate_audio_action", value: "Generate Audio", comment: "Generate audio action"), systemImage: "waveform.badge.plus")
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

                            if library.canModifyCollection(collectionID) {
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
                    .id(track.id)
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

        let trackIds = collection.tracks.map { $0.id.uuidString }
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
                let completedIds = try await GRDBDatabaseManager.shared.fetchTrackIdsWithCompletedSummaries(trackIds: trackIds)
                readyTrackIds = Set(completedIds.compactMap { UUID(uuidString: $0) })
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

    private func attemptAutoFocusIfNeeded(using proxy: ScrollViewProxy) {
        guard
            !didAutoFocusTrack,
            let targetId = pendingAutoFocusTrackId,
            filteredTracks.contains(where: { $0.id == targetId })
        else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
            self.didAutoFocusTrack = true
        }
    }

    private func startPlayback(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let token = authViewModel.token else {
            missingAuthAlert = true
            return
        }

        if audioPlayer.currentTrack?.id == track.id, audioPlayer.isPlaying {
            audioPlayer.togglePlayback()
        } else {
            audioPlayer.play(track: track, in: collection, token: token)
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

        guard clampedTitle != collection.title || clampedDescription != collection.description else { return }

        library.updateCollectionDetails(
            collectionID: collectionID,
            newTitle: clampedTitle,
            newDescription: clampedDescription,
            shouldUpdateDescription: true
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
    
    @ViewBuilder
    private func favoriteSwipeButton(for track: AudiobookTrack, in collection: AudiobookCollection) -> some View {
        Button {
            library.toggleFavorite(for: track.id, in: collection.id)
        } label: {
            Label(
                track.isFavorite
                ? NSLocalizedString("remove_from_favorites", comment: "Remove from favorites")
                : NSLocalizedString("add_to_favorites", comment: "Add to favorites"),
                systemImage: track.isFavorite ? "heart.slash" : "heart"
            )
        }
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
    @State private var transcribingTrackIds: Set<UUID> = []

    // ... (removed duplicates)

    private func loadTranscriptStatus() {
        guard let collection else { return }
        
        // Debounce: Cancel previous task
        transcriptStatusTask?.cancel()

        transcriptStatusTask = Task {
            // Wait 300ms to debounce rapid changes
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            var newCache: [UUID: Bool] = [:]
            let dbManager = GRDBDatabaseManager.shared

            do {
                try await dbManager.initializeDatabase()
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.transcriptStatusCache = [:]
                    }
                }
                return
            }
            
            if Task.isCancelled { return }

            // Fetch all at once if possible, or iterate (iteration is fine for now if off main thread)
            for track in collection.tracks {
                if Task.isCancelled { return }
                do {
                    let hasTranscript = try await dbManager.hasCompletedTranscript(forTrackId: track.id.uuidString)
                    newCache[track.id] = hasTranscript
                } catch {
                    newCache[track.id] = false
                }
            }

            if !Task.isCancelled {
                await MainActor.run {
                    self.transcriptStatusCache = newCache
                }
            }
        }
    }

    private func confirmDeleteTranscript(_ track: AudiobookTrack) {
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
}

private struct CollectionInfoEditorView: View {
    let title: String
    let nameFieldLabel: String
    let descriptionFieldLabel: String
    @Binding var name: String
    @Binding var description: String
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

            FavoriteToggleButton(isFavorite: isFavorite) {
                onToggleFavorite()
            }
            .font(.headline)

            playPauseButton
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

    @ViewBuilder
    private var progressSummaryView: some View {
        if let state = playbackState, state.position > 1 {
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

    private var metadataRow: some View {
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
                    }
                    .foregroundStyle(Color.blue)
                    .accessibilityLabel(NSLocalizedString("transcription_view_running_job", comment: "View running transcription"))
                }
            }

            Spacer()

            if let state = playbackState, state.position > 1 {
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
