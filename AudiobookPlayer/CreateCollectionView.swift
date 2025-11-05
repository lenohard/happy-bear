import SwiftUI

struct CreateCollectionView: View {
    @StateObject private var viewModel: CollectionBuilderViewModel
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let folderPath: String
    let tokenProvider: () -> BaiduOAuthToken?
    let onComplete: (AudiobookCollection) -> Void

    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var selectedTrackIds: Set<UUID> = []    // Phase 1: track selection state
    @State private var showingError = false
    @State private var errorMessage: String = ""

    init(
        folderPath: String,
        tokenProvider: @escaping () -> BaiduOAuthToken?,
        onComplete: @escaping (AudiobookCollection) -> Void
    ) {
        self.folderPath = folderPath
        self.tokenProvider = tokenProvider
        self.onComplete = onComplete
        _viewModel = StateObject(wrappedValue: CollectionBuilderViewModel())
    }

    var body: some View {
        NavigationView {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    loadingView
                case .ready(let draft):
                    readyView(draft: draft)
                case .failed(let error):
                    errorView(error: error)
                }
            }
            .navigationTitle("Import Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await viewModel.buildCollection(
                from: folderPath,
                title: nil,
                tokenProvider: tokenProvider
            )
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            if case .loading(let progress) = viewModel.state {
                VStack(spacing: 8) {
                    Text("Scanning folder...")
                        .font(.headline)
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Preparing...")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readyView(draft: CollectionDraft) -> some View {
        Form {
            Section("Collection Details") {
                TextField("Title", text: $editedTitle)
                    .onAppear {
                        if editedTitle.isEmpty {
                            editedTitle = draft.title
                        }
                    }

                TextField("Description (optional)", text: $editedDescription, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Content") {
                LabeledContent("Tracks", value: "\(draft.totalTrackCount)")
                LabeledContent("Total Size", value: formatBytes(draft.totalSize))

                if !draft.nonAudioFiles.isEmpty {
                    DisclosureGroup("\(draft.nonAudioFiles.count) non-audio files") {
                        ForEach(draft.nonAudioFiles.prefix(10), id: \.self) { filename in
                            Text(filename)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if draft.nonAudioFiles.count > 10 {
                            Text("... and \(draft.nonAudioFiles.count - 10) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Select Tracks") {
                if case .ready(let draft) = viewModel.state {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Button(action: {
                                selectedTrackIds = Set(draft.tracks.map(\.id))
                            }) {
                                Text("Select All")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button(action: {
                                selectedTrackIds.removeAll()
                            }) {
                                Text("Deselect All")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Text("\(selectedTrackIds.count) of \(draft.totalTrackCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 8)

                        List {
                            ForEach(draft.tracks) { track in
                                HStack(spacing: 12) {
                                    Image(systemName: selectedTrackIds.contains(track.id) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(selectedTrackIds.contains(track.id) ? .blue : .gray)

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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedTrackIds.contains(track.id) {
                                        selectedTrackIds.remove(track.id)
                                    } else {
                                        selectedTrackIds.insert(track.id)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }

            Section {
                Button(action: saveCollection) {
                    HStack {
                        Spacer()
                        Text("Add to Library")
                            .font(.headline)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorView(error: CollectionBuildError) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(error.localizedDescription)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if case .expiredToken = error {
                Button("Re-authenticate") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Try Again") {
                Task {
                    await viewModel.buildCollection(
                        from: folderPath,
                        title: nil,
                        tokenProvider: tokenProvider
                    )
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveCollection() {
        guard case .ready(let draft) = viewModel.state else { return }

        // Filter to only selected tracks
        let selectedTracks = draft.tracks.filter {
            selectedTrackIds.contains($0.id)
        }

        guard !selectedTracks.isEmpty else {
            errorMessage = NSLocalizedString("no_tracks_selected_error", comment: "Must select at least one track")
            showingError = true
            return
        }

        let collection = AudiobookCollection(
            id: UUID(),
            title: editedTitle.isEmpty ? draft.title : editedTitle,
            author: nil,
            description: editedDescription.isEmpty ? nil : editedDescription,
            coverAsset: draft.coverSuggestion,
            createdAt: Date(),
            updatedAt: Date(),
            source: .baiduNetdisk(
                folderPath: draft.folderPath,
                tokenScope: tokenProvider()?.scope ?? "netdisk"
            ),
            tracks: selectedTracks,  // Only selected tracks
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: []
        )

        libraryStore.save(collection)
        onComplete(collection)
        dismiss()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    CreateCollectionView(
        folderPath: "/audiobooks/test",
        tokenProvider: { nil },
        onComplete: { _ in }
    )
    .environmentObject(LibraryStore())
}
