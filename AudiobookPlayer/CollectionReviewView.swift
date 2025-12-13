import SwiftUI

struct CollectionReviewView<RowContent: View>: View {
    enum ActionStyle {
        case stickyFooter
        case toolbar(
            cancelTitle: String,
            confirmTitle: String,
            onCancel: () -> Void
        )
    }

    private let title: Binding<String>?
    private let description: Binding<String>?
    let tracks: [AudiobookTrack]
    @Binding var selectedTrackIds: Set<UUID>
    let totalSize: Int64
    let nonPlayableFiles: [String]
    let onSave: () -> Void
    let saveButtonTitle: String
    let actionStyle: ActionStyle
    let selectionListMaxHeight: CGFloat
    
    let headerContent: AnyView?
    let rowContent: (AudiobookTrack) -> RowContent

    @State private var trackSearchText: String = ""
    
    init(
        title: Binding<String>,
        description: Binding<String>,
        tracks: [AudiobookTrack],
        selectedTrackIds: Binding<Set<UUID>>,
        totalSize: Int64,
        nonPlayableFiles: [String] = [],
        actionStyle: ActionStyle = .stickyFooter,
        selectionListMaxHeight: CGFloat = 640,
        saveButtonTitle: String = NSLocalizedString("rss_add_to_library_button", value: "Add to Library", comment: "Add to library button"),
        onSave: @escaping () -> Void,
        headerContent: (() -> AnyView)? = nil,
        @ViewBuilder rowContent: @escaping (AudiobookTrack) -> RowContent
    ) {
        self.title = title
        self.description = description
        self.tracks = tracks
        self._selectedTrackIds = selectedTrackIds
        self.totalSize = totalSize
        self.nonPlayableFiles = nonPlayableFiles
        self.actionStyle = actionStyle
        self.selectionListMaxHeight = selectionListMaxHeight
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        self.headerContent = headerContent?()
        self.rowContent = rowContent
    }

    init(
        tracks: [AudiobookTrack],
        selectedTrackIds: Binding<Set<UUID>>,
        totalSize: Int64,
        nonPlayableFiles: [String] = [],
        actionStyle: ActionStyle = .stickyFooter,
        selectionListMaxHeight: CGFloat = 640,
        saveButtonTitle: String = NSLocalizedString("rss_add_to_library_button", value: "Add to Library", comment: "Add to library button"),
        onSave: @escaping () -> Void,
        headerContent: (() -> AnyView)? = nil,
        @ViewBuilder rowContent: @escaping (AudiobookTrack) -> RowContent
    ) {
        self.title = nil
        self.description = nil
        self.tracks = tracks
        self._selectedTrackIds = selectedTrackIds
        self.totalSize = totalSize
        self.nonPlayableFiles = nonPlayableFiles
        self.actionStyle = actionStyle
        self.selectionListMaxHeight = selectionListMaxHeight
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        self.headerContent = headerContent?()
        self.rowContent = rowContent
    }
    
    var body: some View {
        let visibleTracks = filteredTracks()

        let form = Form {
            if hasDetailsSection {
                Section(NSLocalizedString("collection_details_section", value: "Collection Details", comment: "Section title")) {
                    if let title {
                        TextField(NSLocalizedString("rss_collection_title_field", value: "Title", comment: "Title field"), text: title)
                    }
                    if let description {
                        TextField(NSLocalizedString("rss_collection_description_field", value: "Description (optional)", comment: "Description field"), text: description, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let headerContent {
                        headerContent
                    }
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
                    items: visibleTracks,
                    selectedIds: $selectedTrackIds,
                    topContent: { AnyView(trackSearchRow) },
                    maxHeight: selectionListMaxHeight,
                    summaryFormatter: { selected, _ in
                        String(format: NSLocalizedString("selected_tracks_count", value: "%d of %d", comment: "Selected tracks count"), selected, tracks.count)
                    }
                ) { track, _ in
                    rowContent(track)
                }
            }
        }

        Group {
            if case .stickyFooter = actionStyle {
                ZStack(alignment: .bottom) {
                    form
                        .padding(.bottom, 84)

                    stickyFooter
                        .ignoresSafeArea(edges: .bottom)
                }
            } else {
                form
            }
        }
        .toolbar {
            if case let .toolbar(cancelTitle, confirmTitle, onCancel) = actionStyle {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { onCancel() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onSave() }
                        .disabled(selectedTrackIds.isEmpty)
                }
            }
        }
    }

    private var hasDetailsSection: Bool {
        title != nil || description != nil || headerContent != nil
    }

    private var trackSearchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                NSLocalizedString("search_tracks_prompt", value: "Search tracks", comment: "Search tracks prompt"),
                text: $trackSearchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)

            if !trackSearchText.isEmpty {
                Button {
                    trackSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("clear_button", value: "Clear", comment: "Clear button"))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 4)
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
            .padding(.vertical, 12)
        }
        .background(
            Color(uiColor: .systemBackground)
                .shadow(color: Color.black.opacity(0.1), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func filteredTracks() -> [AudiobookTrack] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }

        return tracks.filter { track in
            track.displayName.localizedCaseInsensitiveContains(query) ||
                track.filename.localizedCaseInsensitiveContains(query)
        }
    }
}
