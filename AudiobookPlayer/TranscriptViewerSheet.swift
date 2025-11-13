import SwiftUI

// MARK: - Transcript Viewer Sheet

/// Sheet for viewing and searching transcripts
struct TranscriptViewerSheet: View {
    let trackId: String
    let trackName: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var baiduAuth: BaiduAuthViewModel
    @StateObject private var viewModel: TranscriptViewModel
    @State private var selectedSegment: TranscriptSegment?
    @State private var playbackAlertMessage: String?

    init(trackId: String, trackName: String) {
        self.trackId = trackId
        self.trackName = trackName
        _viewModel = StateObject(wrappedValue: TranscriptViewModel(trackId: trackId))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                SearchBar(
                    text: $viewModel.searchText,
                    placeholder: "search_in_transcript"
                )
                .padding()

                // Content
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)

                        Text(error)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)

                        Button(action: {
                            Task { await viewModel.loadTranscript() }
                        }) {
                            Text("retry_button")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.segments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.gray)

                        Text("no_transcript_found")
                            .font(.headline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.searchText.isEmpty {
                    // Full transcript view
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentRowView(
                                    segment: segment,
                                    isSelected: selectedSegment?.id == segment.id,
                                    onTap: {
                                        selectedSegment = segment
                                        jumpToSegment(segment)
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                } else {
                    // Search results view
                    if viewModel.searchResults.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)

                            Text("no_search_results")
                                .font(.headline)

                            Text("transcript_search_no_matches")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                SearchSummaryView(
                                    query: viewModel.searchText,
                                    totalMatches: viewModel.searchResults.count
                                )
                                .padding(.horizontal)

                                ForEach(viewModel.searchResults) { result in
                                    SearchResultRow(
                                        result: result,
                                        highlightedText: viewModel.highlightedSegmentText(result.segment),
                                        isSelected: selectedSegment?.id == result.segment.id,
                                        onTap: {
                                            selectedSegment = result.segment
                                            jumpToSegment(result.segment)
                                        }
                                    )
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle(trackName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("close_button") {
                        dismiss()
                    }
                }

                if !viewModel.searchText.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: viewModel.clearSearch) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.loadTranscript()
        }
        .alert(
            NSLocalizedString("error_title", comment: "Generic error title"),
            isPresented: Binding(
                get: { playbackAlertMessage != nil },
                set: { newValue in
                    if !newValue {
                        playbackAlertMessage = nil
                    }
                }
            )
        ) {
            Button("ok_button", role: .cancel) {
                playbackAlertMessage = nil
            }
        } message: {
            Text(playbackAlertMessage ?? "")
        }
    }

    // MARK: - Private Methods

    private func jumpToSegment(_ segment: TranscriptSegment) {
        guard let context = resolveTrackContext() else {
            playbackAlertMessage = NSLocalizedString(
                "transcript_track_not_found_message",
                comment: "Shown when transcript track cannot be located for playback"
            )
            return
        }

        let position = viewModel.getPlaybackPosition(for: segment)

        if audioPlayer.currentTrack?.id != context.track.id || audioPlayer.activeCollection?.id != context.collection.id {
            audioPlayer.play(track: context.track, in: context.collection, token: baiduAuth.token)
        }

        audioPlayer.seek(to: position)

        // Dismiss after a short delay to show selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }

    private func resolveTrackContext() -> (track: AudiobookTrack, collection: AudiobookCollection)? {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return (track, collection)
            }
        }
        return nil
    }
}

// MARK: - Segment Row Component

struct TranscriptSegmentRowView: View {
    let segment: TranscriptSegment
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(segment.formattedStartTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(segment.formattedEndTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.text)
                        .font(.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let confidence = segment.confidence {
                        Text(
                            String(
                                format: NSLocalizedString("transcript_confidence_format", comment: "Transcript confidence percentage"),
                                locale: .current,
                                confidence * 100
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Search Result Row Component

struct SearchResultRow: View {
    let result: TranscriptSearchResult
    let highlightedText: NSAttributedString
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(result.segment.formattedStartTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(matchCountText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundStyle(Color.accentColor)
            }

            AttributedText(highlightedText)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var matchCountText: String {
        if result.matchCount == 1 {
            return NSLocalizedString("transcript_search_result_single", comment: "Single transcript search match")
        } else {
            return String(
                format: NSLocalizedString("transcript_search_result_plural", comment: "Multiple transcript search matches"),
                locale: .current,
                result.matchCount
            )
        }
    }
}

// MARK: - Search Summary

private struct SearchSummaryView: View {
    let query: String
    let totalMatches: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                String(
                    format: NSLocalizedString("transcript_search_results", comment: "Transcript search header"),
                    locale: .current,
                    query
                )
            )
            .font(.headline)

            Text(summaryCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCountText: String {
        if totalMatches == 1 {
            return NSLocalizedString(
                "transcript_search_result_single",
                comment: "Displayed when transcript search has exactly one match"
            )
        } else {
            return String(
                format: NSLocalizedString(
                    "transcript_search_result_plural",
                    comment: "Displayed when transcript search has multiple matches"
                ),
                locale: .current,
                totalMatches
            )
        }
    }
}

// MARK: - Search Bar Component

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString(placeholder, comment: ""), text: $text)
                .textFieldStyle(.roundedBorder)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Attributed Text for Highlighting

struct AttributedText: UIViewRepresentable {
    let attributedString: NSAttributedString

    init(_ attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.attributedText = attributedString
    }
}

// MARK: - Preview

#Preview {
    TranscriptViewerSheet(trackId: "test-track-1", trackName: "Sample Audiobook Track")
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(LibraryStore(autoLoadOnInit: false))
        .environmentObject(BaiduAuthViewModel())
}
