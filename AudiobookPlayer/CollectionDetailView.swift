import SwiftUI

struct CollectionDetailView: View {
    let collectionID: UUID

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var transcriptionManager: TranscriptionManager

    @State private var searchText = ""
    @State private var missingAuthAlert = false
    @State private var showTrackPicker = false
    @State private var trackToDelete: AudiobookTrack?
    @State private var showDeleteConfirmation = false
    @State private var trackToRename: AudiobookTrack?
    @State private var trackTitleDraft = ""
    @State private var showCollectionRenameSheet = false
    @State private var collectionTitleDraft = ""
    @State private var trackForTranscription: AudiobookTrack?
    @State private var trackForViewing: AudiobookTrack?
    @State private var transcriptStatusCache: [UUID: Bool] = [:]
    @State private var pendingAutoFocusTrackId: UUID?
    @State private var didAutoFocusTrack = false
    @State private var trackPendingTranscriptDeletion: AudiobookTrack?
    @State private var showTranscriptDeletionDialog = false
    @State private var transcriptDeletionError: String?
    @State private var showTranscriptDeletionError = false

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
        content
        .navigationTitle(collection?.title ?? NSLocalizedString("collection_title_fallback", comment: "Collection detail fallback title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            prompt: Text(NSLocalizedString("search_tracks_prompt", comment: "Search tracks prompt"))
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if library.canModifyCollection(collectionID) {
                    Button(action: addTracksAction) {
                        Label(
                            NSLocalizedString("add_tracks_button", comment: "Add tracks button"),
                            systemImage: "plus.circle"
                        )
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .alert(NSLocalizedString("connect_baidu_first", comment: "Connect Baidu First alert"), isPresented: $missingAuthAlert) {
            Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("sign_in_on_sources_tab", comment: "Sign in on sources tab message"))
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            let currentCollection = self.collection

            if
                audioPlayer.activeCollection?.id == collectionID,
                let collection = currentCollection,
                let track = audioPlayer.currentTrack
            {
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

            recordPlayback(for: collection, track: track, position: newValue)
        }
        .confirmationDialog(
            NSLocalizedString("remove_track_action", comment: "Remove track dialog title"),
            isPresented: $showDeleteConfirmation,
            presenting: trackToDelete
        ) { _ in
            Button(role: .destructive, action: deleteSelectedTrack) {
                Text(NSLocalizedString("remove_track_action", comment: "Remove track action label"))
            }
            Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) {
                trackToDelete = nil
            }
        } message: { track in
            Text(removePrompt(for: track))
        }
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
        .sheet(isPresented: $showCollectionRenameSheet) {
            RenameEntryView(
                title: NSLocalizedString("rename_collection_title", comment: "Rename collection title"),
                fieldLabel: NSLocalizedString("name_field_label", comment: "Name field label"),
                text: $collectionTitleDraft,
                onSubmit: applyCollectionRename,
                onCancel: cancelCollectionRename
            )
        }
        .onChange(of: trackToRename) { newValue in
            if newValue == nil {
                trackTitleDraft = ""
            }
        }
        .onChange(of: showCollectionRenameSheet) { newValue in
            if !newValue {
                collectionTitleDraft = ""
            }
        }
        .onChange(of: collectionID) { _ in
            resetAutoFocusState()
            loadTranscriptStatus()
            prepareAutoFocusTargetIfNeeded(for: self.collection)
        }
        .onChange(of: collection?.tracks.map(\.id) ?? []) { _ in
            prepareAutoFocusTargetIfNeeded(for: self.collection)
        }
        .onChange(of: audioPlayer.activeCollection?.id) { _ in
            prepareAutoFocusTargetIfNeeded(for: self.collection)
        }
        .onAppear {
            loadTranscriptStatus()
            prepareAutoFocusTargetIfNeeded(for: self.collection)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { notification in
            print("[CollectionDetailView] Received TranscriptionCompleted notification")
            // Reload transcript status when a transcription completes
            loadTranscriptStatus()
        }
        .sheet(item: $trackForTranscription) { track in
            TranscriptionSheet(track: track, collectionID: collectionID)
        }
        .sheet(item: $trackForViewing) { track in
            TranscriptViewerSheet(trackId: track.id.uuidString, trackName: track.displayName)
        }
        .confirmationDialog(
            NSLocalizedString("delete_transcript_confirm_title", comment: "Delete transcript dialog title"),
            isPresented: $showTranscriptDeletionDialog,
            presenting: trackPendingTranscriptDeletion
        ) { track in
            Button(NSLocalizedString("delete_transcript_confirm", comment: "Confirm delete transcript"), role: .destructive) {
                deleteTranscript(for: track)
            }
            Button(NSLocalizedString("delete_transcript_cancel", comment: "Cancel delete transcript"), role: .cancel) {
                trackPendingTranscriptDeletion = nil
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
            List {
                summarySection(collection)
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
        }
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
                Text(String(format: NSLocalizedString("track_count_and_size", comment: "Track count and size"), collection.tracks.count, formatBytes(totalSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if library.canModifyCollection(collectionID) {
                    Menu {
                        Button {
                            beginRenamingCollection(collection)
                        } label: {
                            Label(
                                NSLocalizedString("rename_action", comment: "Rename action"),
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
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func tracksSection(_ collection: AudiobookCollection) -> some View {
        Section {
            if filteredTracks.isEmpty {
                Text(searchText.isEmpty ? NSLocalizedString("no_audio_tracks", comment: "No audio tracks") : String(format: NSLocalizedString("no_search_results", comment: "No search results"), searchText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                    let trackIsActive = isCurrentTrack(track: track)
                    TrackDetailRow(
                        index: index,
                        track: track,
                        isActive: trackIsActive,
                        isPlaying: trackIsActive && audioPlayer.isPlaying,
                        playbackState: collection.playbackState(for: track.id),
                        isFavorite: track.isFavorite,
                        hasTranscript: transcriptStatusCache[track.id] ?? false,
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
                        Button {
                            trackForTranscription = track
                        } label: {
                            Label(
                                NSLocalizedString("transcribe_track_title", comment: "Transcribe track title"),
                                systemImage: "waveform"
                            )
                        }

                        if transcriptStatusCache[track.id] ?? false {
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
                    }
                    .id(track.id)
                }
            }
        }
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

    private func beginRenamingCollection(_ collection: AudiobookCollection) {
        collectionTitleDraft = String(collection.title.prefix(256))
        showCollectionRenameSheet = true
    }

    private func cancelCollectionRename() {
        showCollectionRenameSheet = false
        collectionTitleDraft = ""
    }

    private func applyCollectionRename() {
        let trimmed = collectionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        collectionTitleDraft = ""
        showCollectionRenameSheet = false

        guard !trimmed.isEmpty else { return }
        library.renameCollection(
            collectionID: collectionID,
            newTitle: String(trimmed.prefix(256))
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
        .tint(track.isFavorite ? .pink : .accentColor)
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

    private func loadTranscriptStatus() {
        guard let collection else { return }

        Task {
            var newCache: [UUID: Bool] = [:]
            let dbManager = GRDBDatabaseManager.shared

            do {
                try await dbManager.initializeDatabase()
            } catch {
                await MainActor.run {
                    self.transcriptStatusCache = [:]
                }
                return
            }

            for track in collection.tracks {
                do {
                    let hasTranscript = try await dbManager.hasCompletedTranscript(forTrackId: track.id.uuidString)
                    newCache[track.id] = hasTranscript
                } catch {
                    newCache[track.id] = false
                }
            }

            await MainActor.run {
                self.transcriptStatusCache = newCache
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
}

#Preview {
    CollectionDetailView(collectionID: UUID())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(BaiduAuthViewModel())
        .environmentObject(TranscriptionManager())
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

private struct TrackDetailRow: View {
    let index: Int
    let track: AudiobookTrack
    let isActive: Bool
    let isPlaying: Bool
    let playbackState: TrackPlaybackState?
    let isFavorite: Bool
    let hasTranscript: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(track.displayName)
                        .font(.body)
                        .lineLimit(2)

                    if hasTranscript {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(.blue)
                        .accessibilityLabel(NSLocalizedString("transcript_available", comment: "Transcript available accessibility label"))
                    }
                }

                playbackSummary

                Text(formatBytes(track.fileSize))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            FavoriteToggleButton(isFavorite: isFavorite) {
                onToggleFavorite()
            }

            statusIcon
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var statusIcon: some View {
        Group {
            if isActive {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "play.fill")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var playbackSummary: some View {
        if let state = playbackState, state.position > 1 {
            if let duration = state.duration, duration > 0 {
                let clampedPosition = min(state.position, duration)
                ProgressView(value: clampedPosition, total: duration)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(clampedPosition.formattedTimestamp) / \(duration.formattedTimestamp)")
                    Spacer()
                    Text(percentString(position: clampedPosition, duration: duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Last position: \(state.position.formattedTimestamp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
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
