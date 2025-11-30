import SwiftUI

struct CreateEbookCollectionView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    
    let epubURL: URL
    let onComplete: (AudiobookCollection) -> Void
    
    @State private var editedTitle: String = ""
    @State private var editedAuthor: String = ""
    @State private var editedDescription: String = ""
    @State private var selectedChapterIndices: Set<Int> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showingError = false
    @State private var errorMessage: String = ""
    @State private var previewingChapterIndex: Int?
    
    // Parsed ebook data
    @State private var bookTitle: String = ""
    @State private var bookAuthor: String?
    @State private var chapters: [EpubChapter] = []
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                Group {
                    if isLoading {
                        loadingView
                    } else if let error = loadError {
                        errorView(error: error)
                    } else {
                        readyView
                            .padding(.bottom, 80) // Space for sticky footer
                    }
                }
                
                // Sticky footer - only show when ready
                if !isLoading && loadError == nil {
                    stickyFooter
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
        .sheet(item: Binding(
            get: { previewingChapterIndex.map { PreviewChapter(index: $0, chapter: chapters[$0]) } },
            set: { previewingChapterIndex = $0?.index }
        )) { preview in
            NavigationView {
                ScrollView {
                    Text(preview.chapter.content)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(preview.chapter.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            previewingChapterIndex = nil
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
        Form {
            Section("Book Details") {
                TextField("Title", text: $editedTitle)
                    .onAppear {
                        if editedTitle.isEmpty {
                            editedTitle = bookTitle
                        }
                        if editedAuthor.isEmpty {
                            editedAuthor = bookAuthor ?? ""
                        }
                        // Auto-select all chapters by default
                        if selectedChapterIndices.isEmpty {
                            selectedChapterIndices = Set(chapters.indices)
                        }
                    }
                
                TextField("Author (optional)", text: $editedAuthor)
                
                TextField("Description (optional)", text: $editedDescription, axis: .vertical)
                    .lineLimit(3...6)
            }
            
            Section("Content") {
                LabeledContent("Chapters", value: "\(chapters.count)")
                
                if let author = bookAuthor, !author.isEmpty {
                    LabeledContent("Author", value: author)
                }
            }
            
            Section("Select Chapters") {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Button(action: {
                            selectedChapterIndices = Set(chapters.indices)
                        }) {
                            Text("Select All")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Button(action: {
                            selectedChapterIndices.removeAll()
                        }) {
                            Text("Deselect All")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Text("\(selectedChapterIndices.count) of \(chapters.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 8)
                    
                    List {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            HStack(spacing: 12) {
                                Button(action: {
                                    if selectedChapterIndices.contains(index) {
                                        selectedChapterIndices.remove(index)
                                    } else {
                                        selectedChapterIndices.insert(index)
                                    }
                                }) {
                                    Image(systemName: selectedChapterIndices.contains(index) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(selectedChapterIndices.contains(index) ? .blue : .gray)
                                }
                                .buttonStyle(.plain)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title)
                                        .font(.body)
                                        .lineLimit(2)
                                    
                                    Text("\(chapter.content.count) characters")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    previewingChapterIndex = index
                                }) {
                                    Image(systemName: "eye.circle")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
    }
    
    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Chapters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("\(selectedChapterIndices.count) of \(chapters.count)")
                        .font(.headline)
                }
                
                Spacer()
                
                Button {
                    saveCollection()
                } label: {
                    Text("Add to Library")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedChapterIndices.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .background(
            Color(uiColor: .systemBackground)
                .shadow(color: Color.black.opacity(0.1), radius: 8, y: -2)
        )
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
            
            await MainActor.run {
                self.bookTitle = title
                self.bookAuthor = author
                self.chapters = parsedChapters
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
        guard !chapters.isEmpty else {
            errorMessage = "No chapters found in ebook"
            showingError = true
            return
        }
        
        guard !selectedChapterIndices.isEmpty else {
            errorMessage = "Please select at least one chapter"
            showingError = true
            return
        }
        
        let collectionId = UUID()
        let now = Date()
        
        // Filter selected chapters and create tracks
        let sortedIndices = selectedChapterIndices.sorted()
        let tracks = sortedIndices.map { index in
            let chapter = chapters[index]
            return AudiobookTrack(
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
            tracks: tracks,
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: []
        )
        
        libraryStore.save(collection)
        onComplete(collection)
        dismiss()
    }
}

private struct PreviewChapter: Identifiable {
    let index: Int
    let chapter: EpubChapter
    var id: Int { index }
}

#Preview {
    CreateEbookCollectionView(
        epubURL: URL(fileURLWithPath: "/tmp/sample.epub"),
        onComplete: { _ in }
    )
    .environmentObject(LibraryStore())
}
