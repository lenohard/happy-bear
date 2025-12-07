import SwiftUI

struct AddRSSCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var feedURL: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var parsedFeed: RSSFeed?
    @State private var collectionTitle: String = ""
    @State private var collectionDescription: String = ""
    @State private var selectedTrackIds: Set<UUID> = []
    
    var body: some View {
        NavigationStack {
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
                
                if let feed = parsedFeed {
                    feedPreviewSection(feed)
                    
                    Section {
                        Button(NSLocalizedString("rss_add_to_library_button", value: "Add to Library", comment: "Add RSS feed to library button")) {
                            addCollection()
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || selectedTrackIds.isEmpty)
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
    
    @ViewBuilder
    private func feedPreviewSection(_ feed: RSSFeed) -> some View {
        Section(NSLocalizedString("rss_feed_preview_section_title", value: "Feed Preview", comment: "RSS feed preview section title")) {
            TextField(NSLocalizedString("rss_collection_title_field", value: "Collection Title", comment: "RSS collection title field"), text: $collectionTitle)
            TextField(NSLocalizedString("rss_collection_description_field", value: "Description (optional)", comment: "RSS collection description field"), text: $collectionDescription, axis: .vertical)
                .lineLimit(3...6)
            
            LabeledContent {
                Text("\(feed.items.count)")
            } label: {
                Text(NSLocalizedString("rss_episode_count_label", value: "Total Episodes", comment: "RSS episode count label"))
            }
            
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: {
                        let allIds = feed.items.enumerated().map { index, _ in uuid(for: index) }
                        selectedTrackIds = Set(allIds)
                    }) {
                        Text(NSLocalizedString("select_all_button", value: "Select All", comment: "Select all tracks button"))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: {
                        selectedTrackIds.removeAll()
                    }) {
                        Text(NSLocalizedString("deselect_all_button", value: "Deselect All", comment: "Deselect all tracks button"))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Text("\(selectedTrackIds.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            
            if !feed.items.isEmpty {
                ForEach(Array(feed.items.enumerated()), id: \.offset) { index, item in
                    let id = uuid(for: index)
                    HStack(spacing: 12) {
                        Image(systemName: selectedTrackIds.contains(id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(selectedTrackIds.contains(id) ? .blue : .gray)
                            .onTapGesture {
                                if selectedTrackIds.contains(id) {
                                    selectedTrackIds.remove(id)
                                } else {
                                    selectedTrackIds.insert(id)
                                }
                            }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(2)
                            
                            HStack {
                                if let pubDate = item.pubDate {
                                    Text(pubDate.formatted(date: .abbreviated, time: .omitted))
                                }
                                Text(formatBytes(item.enclosureLength))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    // Stable UUID generation for items based on index (since we recreate them on parse)
    // In a real app, we might use item GUID if available and unique, but index is safe for this temporary list
    private func uuid(for index: Int) -> UUID {
        // We need stable IDs for the selection set during this session. 
        // We can generate them deterministically or just store them in a parallel array if we wanted.
        // For simplicity, let's just use a deterministic UUID based on index + feedURL to persist across redraws?
        // Actually, State persistence is fine. But we need to map index to UUID consistently.
        // Let's generate a list of UUIDs when feed is parsed.
        return itemUUIDs[index]
    }
    
    @State private var itemUUIDs: [UUID] = []
    
    private func fetchFeed() {
        let trimmedURLString = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURLString), !trimmedURLString.isEmpty else {
            errorMessage = NSLocalizedString("rss_error_invalid_url", value: "Invalid RSS feed URL", comment: "Invalid RSS URL message")
            showError = true
            return
        }
        
        isLoading = true
        errorMessage = nil
        parsedFeed = nil
        selectedTrackIds.removeAll()
        itemUUIDs.removeAll()
        
        Task {
            do {
                let parser = RSSParser()
                let feed = try await parser.parse(url: url)
                
                await MainActor.run {
                    parsedFeed = feed
                    collectionTitle = feed.title
                    collectionDescription = feed.description ?? ""
                    // Generate stable UUIDs for this session
                    itemUUIDs = (0..<feed.items.count).map { _ in UUID() }
                    // Default select all
                    selectedTrackIds = Set(itemUUIDs)
                    isLoading = false
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
        guard let feedURL = URL(string: trimmedURLString) else { return }
        
        let isoFormatter = ISO8601DateFormatter()
        
        let tracks = feed.items.enumerated().compactMap { index, item -> AudiobookTrack? in
            guard index < itemUUIDs.count, selectedTrackIds.contains(itemUUIDs[index]) else { return nil }
            guard let enclosureURL = item.enclosureURL else { return nil }
            
            var metadata: [String: String] = [:]
            if let pubDate = item.pubDate {
                metadata["pubDate"] = isoFormatter.string(from: pubDate)
            }
            if let description = item.description, !description.isEmpty {
                metadata["description"] = description
            }
            
            let filename = enclosureURL.lastPathComponent.isEmpty
                ? "episode-\(index + 1)"
                : enclosureURL.lastPathComponent
            
            return AudiobookTrack(
                id: UUID(),
                displayName: item.title,
                filename: filename,
                location: .external(url: enclosureURL),
                fileSize: item.enclosureLength,
                duration: nil,
                trackNumber: index + 1,
                checksum: item.guid,
                metadata: metadata,
                mediaKind: .audio
            )
        }
        
        guard !tracks.isEmpty else { return }
        
        let resolvedTitle = collectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = resolvedTitle.isEmpty ? feed.title : resolvedTitle
        
        let resolvedDescription = collectionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription: String?
        if !resolvedDescription.isEmpty {
            finalDescription = resolvedDescription
        } else {
            finalDescription = feed.description
        }
        
        let cover: CollectionCover
        if let imageURL = feed.imageURL {
            cover = CollectionCover(kind: .remote(url: imageURL), dominantColorHex: nil)
        } else {
            cover = CollectionCover.generatedCover(for: finalTitle)
        }
        
        let collection = AudiobookCollection(
            id: UUID(),
            title: finalTitle,
            author: nil,
            description: finalDescription,
            coverAsset: cover,
            createdAt: Date(),
            updatedAt: Date(),
            source: .rss(feedUrl: feedURL),
            tracks: tracks,
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: ["podcast", "rss"]
        )
        
        library.save(collection)
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
    AddRSSCollectionView()
        .environmentObject(LibraryStore(autoLoadOnInit: false))
}
