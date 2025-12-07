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
            .ignoresSafeArea(edges: .bottom)
            .simultaneousGesture(
                TapGesture().onEnded {
                    resignFirstResponder()   // allow taps outside fields to hide keyboard
                }
            )
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
        CollectionReviewView(
            title: $editedTitle,
            description: $editedDescription,
            tracks: draft.tracks,
            selectedTrackIds: $selectedTrackIds,
            totalSize: draft.totalSize,
            nonPlayableFiles: draft.nonPlayableFiles,
            onSave: saveCollection
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
        .onAppear {
            if editedTitle.isEmpty {
                editedTitle = draft.title
            }
            // Auto-select all tracks by default
            if selectedTrackIds.isEmpty {
                selectedTrackIds = Set(draft.tracks.map(\.id))
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
