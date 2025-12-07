import SwiftUI

struct CreateEbookCollectionView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    
    let epubURL: URL
    let onComplete: (AudiobookCollection) -> Void
    
    @State private var editedTitle: String = ""
    @State private var editedAuthor: String = ""
    @State private var editedDescription: String = ""
    @State private var selectedTrackIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showingError = false
    @State private var errorMessage: String = ""
    @State private var previewingTrack: AudiobookTrack?
    
    // Parsed ebook data
    @State private var bookTitle: String = ""
    @State private var bookAuthor: String?
    @State private var previewTracks: [AudiobookTrack] = []
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    loadingView
                } else if let error = loadError {
                    errorView(error: error)
                } else {
                    readyView
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .simultaneousGesture(
                TapGesture().onEnded {
                    resignFirstResponder()
                }
            )
            .navigationTitle("Import Ebook")
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
            await parseEbook()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .sheet(item: $previewingTrack) { track in
            NavigationView {
                ScrollView {
                    if case .text(let content) = track.location {
                        Text(content)
                            .padding()
                            .textSelection(.enabled)
                    }
                }
                .navigationTitle(track.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            previewingTrack = nil
                        }
                    }
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Parsing ebook...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Failed to parse ebook")
                .font(.headline)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var readyView: some View {
        CollectionReviewView(
            title: $editedTitle,
            description: $editedDescription,
            tracks: previewTracks,
            selectedTrackIds: $selectedTrackIds,
            totalSize: previewTracks.reduce(0) { $0 + $1.fileSize },
            nonPlayableFiles: [],
            onSave: saveCollection,
            headerContent: {
                AnyView(
                    TextField("Author (optional)", text: $editedAuthor)
                )
            }
        ) { track in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayName)
                        .font(.body)
                        .lineLimit(2)
                    
                    if let count = track.characterCount {
                        Text("\(count) characters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                         Text(formatBytes(track.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    previewingTrack = track
                }) {
                    Image(systemName: "eye.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                Text("\(track.trackNumber)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if editedTitle.isEmpty {
                editedTitle = bookTitle
            }
            if editedAuthor.isEmpty {
                editedAuthor = bookAuthor ?? ""
            }
            // Auto-select all tracks by default
            if selectedTrackIds.isEmpty {
                selectedTrackIds = Set(previewTracks.map(\.id))
            }
        }
    }
    
    private func parseEbook() async {
        isLoading = true
        loadError = nil
        
        // Security-scoped URLs from file picker need explicit access
        let accessing = epubURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                epubURL.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let parser = EpubParser()
            let (title, author, parsedChapters) = try parser.parse(epubURL: epubURL)
            
            // Convert to tracks immediately
            let tracks = parsedChapters.enumerated().map { index, chapter in
                AudiobookTrack(
                    id: UUID(),
                    displayName: chapter.title,
                    filename: chapter.filename,
                    location: .text(content: chapter.content),
                    fileSize: Int64(chapter.content.utf8.count),
                    duration: nil,
                    trackNumber: index + 1,
                    checksum: nil,
                    metadata: [:],
                    isFavorite: false,
                    favoritedAt: nil,
                    characterCount: chapter.content.count
                )
            }
            
            await MainActor.run {
                self.bookTitle = title
                self.bookAuthor = author
                self.previewTracks = tracks
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func saveCollection() {
        guard !previewTracks.isEmpty else {
            errorMessage = "No chapters found in ebook"
            showingError = true
            return
        }
        
        let selectedTracks = previewTracks.filter { selectedTrackIds.contains($0.id) }
        
        guard !selectedTracks.isEmpty else {
            errorMessage = "Please select at least one chapter"
            showingError = true
            return
        }
        
        let collectionId = UUID()
        let now = Date()
        
        let finalTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAuthor = editedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let collection = AudiobookCollection(
            id: collectionId,
            title: finalTitle.isEmpty ? bookTitle : finalTitle,
            author: finalAuthor.isEmpty ? nil : finalAuthor,
            description: finalDescription.isEmpty ? nil : finalDescription,
            coverAsset: .generatedCover(for: finalTitle.isEmpty ? bookTitle : finalTitle),
            createdAt: now,
            updatedAt: now,
            source: .ebook(importedDate: now),
            tracks: selectedTracks,
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
    CreateEbookCollectionView(
        epubURL: URL(fileURLWithPath: "/tmp/sample.epub"),
        onComplete: { _ in }
    )
    .environmentObject(LibraryStore())
}
