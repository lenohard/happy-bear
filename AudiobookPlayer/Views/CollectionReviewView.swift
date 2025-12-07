import SwiftUI

struct CollectionReviewView<RowContent: View>: View {
    @Binding var title: String
    @Binding var description: String
    let tracks: [AudiobookTrack]
    @Binding var selectedTrackIds: Set<UUID>
    let totalSize: Int64
    let nonPlayableFiles: [String]
    let onSave: () -> Void
    let saveButtonTitle: String
    
    let headerContent: AnyView?
    let rowContent: (AudiobookTrack) -> RowContent
    
    init(
        title: Binding<String>,
        description: Binding<String>,
        tracks: [AudiobookTrack],
        selectedTrackIds: Binding<Set<UUID>>,
        totalSize: Int64,
        nonPlayableFiles: [String] = [],
        saveButtonTitle: String = NSLocalizedString("rss_add_to_library_button", value: "Add to Library", comment: "Add to library button"),
        onSave: @escaping () -> Void,
        headerContent: (() -> AnyView)? = nil,
        @ViewBuilder rowContent: @escaping (AudiobookTrack) -> RowContent
    ) {
        self._title = title
        self._description = description
        self.tracks = tracks
        self._selectedTrackIds = selectedTrackIds
        self.totalSize = totalSize
        self.nonPlayableFiles = nonPlayableFiles
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        self.headerContent = headerContent?()
        self.rowContent = rowContent
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                Section(NSLocalizedString("collection_details_section", value: "Collection Details", comment: "Section title")) {
                    TextField(NSLocalizedString("rss_collection_title_field", value: "Title", comment: "Title field"), text: $title)
                    TextField(NSLocalizedString("rss_collection_description_field", value: "Description (optional)", comment: "Description field"), text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    
                    if let headerContent {
                        headerContent
                    }
                }
                
                Section(NSLocalizedString("content_section", value: "Content", comment: "Section title")) {
                    LabeledContent(NSLocalizedString("tracks_label", value: "Tracks", comment: "Tracks label"), value: "\(tracks.count)")
                    LabeledContent(NSLocalizedString("total_size_label", value: "Total Size", comment: "Total size label"), value: formatBytes(totalSize))
                    
                    if !nonPlayableFiles.isEmpty {
                        DisclosureGroup(String(format: NSLocalizedString("non_playable_files_count", value: "%d non-media files", comment: "Count of non-playable files"), nonPlayableFiles.count)) {
                            ForEach(nonPlayableFiles.prefix(10), id: \.self) { filename in
                                Text(filename)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if nonPlayableFiles.count > 10 {
                                Text(String(format: NSLocalizedString("and_more_files", value: "... and %d more", comment: "More files count"), nonPlayableFiles.count - 10))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                Section(NSLocalizedString("select_tracks_section", value: "Select Tracks", comment: "Select tracks section")) {
                    SelectionList(
                        items: tracks,
                        selectedIds: $selectedTrackIds,
                        summaryFormatter: { selected, total in
                            String(format: NSLocalizedString("selected_tracks_count", value: "%d of %d", comment: "Selected tracks count"), selected, total)
                        }
                    ) { track, _ in
                        rowContent(track)
                    }
                }
            }
            .padding(.bottom, 80) // Space for footer
            
            stickyFooter
        }
    }
    
    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("selected_tracks_label", value: "Selected Tracks", comment: "Selected tracks label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("\(selectedTrackIds.count) of \(tracks.count)")
                        .font(.headline)
                }
                
                Spacer()
                
                Button(action: onSave) {
                    Text(saveButtonTitle)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTrackIds.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .background(
            Color(uiColor: .systemBackground)
                .shadow(color: Color.black.opacity(0.1), radius: 8, y: -2)
        )
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
