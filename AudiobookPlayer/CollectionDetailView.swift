import SwiftUI

struct CollectionDetailView: View {
    let collectionID: UUID

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var searchText = ""
    @State private var missingAuthAlert = false
    @State private var showTrackPicker = false
    @State private var trackToDelete: AudiobookTrack?
    @State private var showDeleteConfirmation = false

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
        .task(id: collection?.updatedAt) {
            guard let collection = collection else { return }
            audioPlayer.prepareCollection(collection)
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            guard
                audioPlayer.activeCollection?.id == collectionID,
                let collection,
                let track = audioPlayer.currentTrack
            else { return }

            recordPlayback(for: collection, track: track, position: audioPlayer.currentTime)
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
        List {
            summarySection(collection)
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
                Text(String(format: NSLocalizedString("track_count_and_size", comment: "Track count and size"), collection.tracks.count, formatBytes(totalSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Button {
                        startPlayback(track, in: collection)
                    } label: {
                        TrackRow(
                            index: index,
                            track: track,
                            isActive: isCurrentTrack(track: track),
                            playbackState: collection.playbackState(for: track.id)
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        if library.canModifyCollection(collectionID) {
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
                }
            }
        }
    }

    private func startPlayback(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let token = authViewModel.token else {
            missingAuthAlert = true
            return
        }

        audioPlayer.play(track: track, in: collection, token: token)
        recordPlayback(for: collection, track: track, position: audioPlayer.currentTime)
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
}

private struct TrackRow: View {
    let index: Int
    let track: AudiobookTrack
    let isActive: Bool
    let playbackState: TrackPlaybackState?

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.displayName)
                    .font(.body)
                    .lineLimit(2)

                playbackSummary

                Text(formatBytes(track.fileSize))
                    .font(.caption2)
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

private struct TrackPickerView: View {
    let collectionID: UUID
    let onTracksSelected: ([AudiobookTrack]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var selectedEntries: [BaiduNetdiskEntry] = []
    @State private var errorMessage: IdentifiedError?
    @State private var isBrowserPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                selectionHeader

                BaiduNetdiskBrowserView(
                    tokenProvider: { authViewModel.token },
                    onSelectFile: { entry in toggleSelection(entry) },
                    selectedEntryIDs: Set(selectedEntries.map { $0.fsId }),
                    onToggleSelection: { entry in toggleSelection(entry) }
                )

                selectedList

                footerControls
            }
            .navigationTitle(NSLocalizedString("add_tracks_button", comment: "Track picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", comment: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .alert(item: $errorMessage) { message in
                Alert(
                    title: Text(NSLocalizedString("error_title", comment: "Error title")),
                    message: Text(message.message),
                    dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK")))
                )
            }
        }
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: validateState)
    }

    private var selectionHeader: some View {
        VStack(spacing: 4) {
            Text(String(format: NSLocalizedString("track_picker_selected_count", comment: "Selected count"), selectedEntries.count))
                .font(.title3.weight(.semibold))
            Text(NSLocalizedString("track_picker_selection_summary", comment: "Selection summary"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var selectedList: some View {
        Group {
            if selectedEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    Text(NSLocalizedString("track_picker_placeholder_title", comment: "Placeholder title"))
                        .font(.headline)

                    Text(NSLocalizedString("track_picker_placeholder_message", comment: "Placeholder message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                List {
                    ForEach(selectedEntries, id: \.fsId) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.serverFilename)
                                    .font(.body)
                                    .lineLimit(2)

                                Text(entry.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)

                                Text(formatBytes(entry.size))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                toggleSelection(entry)
                            } label: {
                                Label(NSLocalizedString("track_picker_remove_selected", comment: "Remove selected"), systemImage: "minus.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .frame(maxHeight: 220)
            }
        }
    }

    private var footerControls: some View {
        VStack(spacing: 12) {
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("track_picker_selection_summary", comment: "Selection summary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(format: NSLocalizedString("track_picker_selected_count", comment: "Selected count"), selectedEntries.count))
                        .font(.headline)
                }

                Spacer()

                Button(NSLocalizedString("track_picker_add_selected", comment: "Add selected")) {
                    addSelectedTracks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func validateState() {
        guard library.canModifyCollection(collectionID) else {
            errorMessage = IdentifiedError(message: NSLocalizedString("track_picker_collection_readonly", comment: "Collection read-only message"))
            return
        }

        guard authViewModel.token != nil else {
            errorMessage = IdentifiedError(message: NSLocalizedString("connect_baidu_first", comment: "Connect Baidu first"))
            return
        }
    }

    private func toggleSelection(_ entry: BaiduNetdiskEntry) {
        guard !entry.isDir else { return }

        if let index = selectedEntries.firstIndex(where: { $0.fsId == entry.fsId }) {
            selectedEntries.remove(at: index)
        } else {
            selectedEntries.append(entry)
        }
    }

    private func addSelectedTracks() {
        let existingCount = library.collections.first { $0.id == collectionID }?.tracks.count ?? 0

        let newTracks: [AudiobookTrack] = selectedEntries.enumerated().map { offset, entry in
            AudiobookTrack(
                id: UUID(),
                displayName: entry.serverFilename,
                filename: entry.serverFilename,
                location: .baidu(fsId: entry.fsId, path: entry.path),
                fileSize: entry.size,
                duration: nil,
                trackNumber: existingCount + offset + 1,
                checksum: entry.md5,
                metadata: [:]
            )
        }

        guard !newTracks.isEmpty else { return }

        onTracksSelected(newTracks)
        dismiss()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct IdentifiedError: Identifiable {
    let id = UUID()
    let message: String
}
