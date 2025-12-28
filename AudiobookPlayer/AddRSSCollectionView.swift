import SwiftUI

struct AddRSSCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var feedURL: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var parsedFeed: RSSFeed?
    @State private var previewTracks: [AudiobookTrack] = []
    
    @State private var collectionTitle: String = ""
    @State private var collectionDescription: String = ""
    @State private var selectedTrackIds: Set<UUID> = []
    
    var body: some View {
        NavigationStack {
            Group {
                if let feed = parsedFeed {
                    CollectionReviewView(
                        title: $collectionTitle,
                        description: $collectionDescription,
                        tracks: previewTracks,
                        selectedTrackIds: $selectedTrackIds,
                        totalSize: previewTracks.reduce(0) { $0 + $1.fileSize },
                        nonPlayableFiles: [],
                        onSave: addCollection
                    ) { track in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayName)
                                .font(.subheadline)
                                .lineLimit(2)
                            
                            HStack {
                                if let pubDate = track.metadata["pubDate"] {
                                    Text(pubDate)
                                }
                                Text(formatBytes(track.fileSize))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Form {
                        Section(NSLocalizedString("rss_feed_url_section_title", value: "RSS Feed URL", comment: "RSS feed URL section title")) {
                            TextField(NSLocalizedString("rss_feed_url_placeholder", value: "https://example.com/podcast/feed.xml", comment: "RSS feed URL placeholder"), text: $feedURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            
                            Button(NSLocalizedString("rss_fetch_button", value: "Fetch Feed", comment: "Fetch RSS feed button")) {
                                fetchFeed()
                            }
                            .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                        }
                        
                        if isLoading {
                            Section {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .padding()
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("rss_import_navigation_title", value: "Import RSS Feed", comment: "RSS import sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", comment: "Cancel button")) {
                        dismiss()
                    }
                }
            }
            .alert(NSLocalizedString("error_title", comment: "Generic error title"), isPresented: $showError) {
                Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
    
    // Stable UUID generation no longer needed as we generate tracks once
    
    private func fetchFeed() {
        let trimmedURLString = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = parseFeedURL(from: trimmedURLString) else {
            errorMessage = NSLocalizedString("rss_error_invalid_url", value: "Invalid RSS feed URL", comment: "Invalid RSS URL message")
            showError = true
            return
        }
        
        isLoading = true
        errorMessage = nil
        parsedFeed = nil
        previewTracks = []
        selectedTrackIds.removeAll()
        
        Task {
            do {
                let parser = RSSParser()
                let feed = try await parser.parse(url: url)
                let isoFormatter = ISO8601DateFormatter()

                // Sort items by pubDate (oldest first) before assigning track numbers
                // Items without pubDate are placed at the end
                let sortedItems = feed.items.sorted { item1, item2 in
                    switch (item1.pubDate, item2.pubDate) {
                    case (let date1?, let date2?):
                        return date1 < date2  // Oldest first
                    case (nil, _?):
                        return false  // Items without date go to the end
                    case (_?, nil):
                        return true   // Items with date come before items without
                    case (nil, nil):
                        return false  // Preserve original order for items without dates
                    }
                }

                // Convert to tracks immediately
                let tracks = sortedItems.enumerated().map { index, item -> AudiobookTrack in
                    var metadata: [String: String] = [:]
                    if let pubDate = item.pubDate {
                        metadata["pubDate"] = isoFormatter.string(from: pubDate)
                    }
                    if let description = item.description, !description.isEmpty {
                        metadata["description"] = description
                    }
                    
                    let filename = item.enclosureURL.lastPathComponent.isEmpty
                        ? "episode-\(index + 1)"
                        : item.enclosureURL.lastPathComponent
                    
                    return AudiobookTrack(
                        id: UUID(),
                        displayName: item.title,
                        filename: filename,
                        location: .external(url: item.enclosureURL),
                        fileSize: item.enclosureLength,
                        duration: nil,
                        trackNumber: index + 1,
                        checksum: item.guid,
                        metadata: metadata,
                        mediaKind: .audio
                    )
                }
                
                await MainActor.run {
                    parsedFeed = feed
                    collectionTitle = feed.title
                    collectionDescription = feed.description ?? ""
                    previewTracks = tracks
                    // Default select all
                    selectedTrackIds = Set(tracks.map(\.id))
                    isLoading = false
                    // If user pasted an http:// URL (or omitted a scheme), keep the UI in sync with what we actually use.
                    feedURL = url.absoluteString
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isLoading = false
                }
            }
        }
    }
    
    private func addCollection() {
        guard let feed = parsedFeed else { return }
        let trimmedURLString = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let feedURL = parseFeedURL(from: trimmedURLString) else { return }
        
        let selectedTracks = previewTracks.filter { selectedTrackIds.contains($0.id) }
        guard !selectedTracks.isEmpty else { return }
        
        let resolvedTitle = collectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = resolvedTitle.isEmpty ? feed.title : resolvedTitle
        
        let resolvedDescription = collectionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = resolvedDescription.isEmpty ? nil : resolvedDescription
        
        let collectionID = UUID()
        
        Task {
            let cover = await resolveCoverAsset(for: feed, title: finalTitle, collectionID: collectionID)
            let collection = AudiobookCollection(
                id: collectionID,
                title: finalTitle,
                author: nil,
                description: finalDescription,
                coverAsset: cover,
                createdAt: Date(),
                updatedAt: Date(),
                source: .rss(feedUrl: feedURL),
                tracks: selectedTracks,
                lastPlayedTrackId: nil,
                playbackStates: [:],
                tags: ["podcast", "rss"]
            )
            
            await MainActor.run {
                library.save(collection)
                dismiss()
            }
        }
    }
    private func resolveCoverAsset(for feed: RSSFeed, title: String, collectionID: UUID) async -> CollectionCover {
        guard let imageURL = feed.imageURL else {
            return CollectionCover.generatedCover(for: title)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            guard !data.isEmpty else {
                return CollectionCover(kind: .remote(url: imageURL), dominantColorHex: nil)
            }
            
            let relativePath = try await CollectionCoverImageStore.shared.saveImageData(
                data,
                for: collectionID,
                replacing: nil
            )
            
            return CollectionCover(
                kind: .image(relativePath: relativePath),
                dominantColorHex: nil
            )
        } catch {
            AppLog.debug("[AddRSSCollectionView] Failed to download RSS cover: \(error.localizedDescription)")
            return CollectionCover(kind: .remote(url: imageURL), dominantColorHex: nil)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func parseFeedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)?.upgradedToHTTPSIfHTTP()
    }
}

#Preview {
    AddRSSCollectionView()
        .environmentObject(LibraryStore(autoLoadOnInit: false))
}

// RSSSelectableItem no longer needed
