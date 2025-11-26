import SwiftUI

/// Simple card that links to the full TranscriptCorrectionsView page
struct TranscriptCorrectionsCard: View {
    let track: AudiobookTrack
    @StateObject private var viewModel = TranscriptCorrectionViewModel()

    var body: some View {
        NavigationLink {
            TranscriptCorrectionsView(
                trackId: track.id.uuidString,
                trackName: track.displayName
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript Corrections")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if viewModel.isLoading {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if viewModel.corrections.isEmpty {
                        Text("Add corrections to fix transcript errors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let applied = viewModel.corrections.filter { $0.isApplied }.count
                        Text("\(viewModel.corrections.count) corrections • \(applied) applied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            viewModel.setTrackId(track.id.uuidString)
        }
    }
}
