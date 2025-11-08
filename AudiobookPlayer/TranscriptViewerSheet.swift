import SwiftUI

// MARK: - Transcript Viewer Sheet

/// Sheet for viewing and searching transcripts
struct TranscriptViewerSheet: View {
    let trackId: String
    let trackName: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @StateObject private var viewModel: TranscriptViewModel
    @State private var selectedSegment: TranscriptSegment?

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

                        Button(action: { viewModel.loadTranscript() }) {
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
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentRow(
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
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(format: NSLocalizedString("transcript_search_results", comment: ""), viewModel.searchText))
                                    .font(.headline)
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
        .onAppear {
            viewModel.loadTranscript()
        }
    }

    // MARK: - Private Methods

    private func jumpToSegment(_ segment: TranscriptSegment) {
        let position = viewModel.getPlaybackPosition(for: segment)
        audioPlayer.seek(to: position)

        // Dismiss after a short delay to show selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }
}

// MARK: - Segment Row Component

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Timestamp
                Text(segment.formattedStartTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.text)
                        .font(.body)
                        .lineLimit(3)

                    if let confidence = segment.confidence {
                        Text(String(format: "Confidence: %.0f%%", confidence * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.1) : Color(.systemBackground))
        .cornerRadius(8)
        .border(isSelected ? Color.blue : Color.clear, width: 2)
    }
}

// MARK: - Search Result Row Component

struct SearchResultRow: View {
    let result: TranscriptSearchResult
    let highlightedText: NSAttributedString
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Timestamp
                Text(result.segment.formattedStartTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                // Match info
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.displayText)
                        .font(.caption)
                        .foregroundStyle(.blue)

                    AttributedText(highlightedText)
                        .font(.body)
                        .lineLimit(2)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.1) : Color(.systemBackground))
        .cornerRadius(8)
        .border(isSelected ? Color.blue : Color.clear, width: 2)
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
}
