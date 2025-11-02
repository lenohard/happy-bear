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
    @State private var showingError = false

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
                LabeledContent("Tracks", value: "\(draft.trackCount)")
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

            Section("Tracks Preview") {
                ForEach(draft.tracks.prefix(10)) { track in
                    HStack {
                        Text("\(track.trackNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 30)

                        VStack(alignment: .leading) {
                            Text(track.displayName)
                                .font(.body)
                            Text(formatBytes(track.fileSize))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if draft.trackCount > 10 {
                    Text("... and \(draft.trackCount - 10) more tracks")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
            tracks: draft.tracks,
            lastPlayedTrackId: nil,
            lastPlaybackPosition: nil,
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
