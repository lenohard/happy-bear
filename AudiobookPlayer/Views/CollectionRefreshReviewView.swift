import SwiftUI

struct CollectionRefreshReviewView: View {
    @Binding var title: String
    @Binding var description: String
    let candidateTracks: [AudiobookTrack]
    @Binding var selectedCandidateIds: Set<UUID>
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        CollectionReviewView(
            title: $title,
            description: $description,
            tracks: candidateTracks,
            selectedTrackIds: $selectedCandidateIds,
            totalSize: candidateTracks.reduce(0) { $0 + $1.fileSize },
            nonPlayableFiles: [],
            saveButtonTitle: NSLocalizedString("add_tracks_button", comment: "Add Tracks"),
            onSave: onSave
        ) { track in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayName)
                        .font(.body)
                        .lineLimit(2)

                    Text(formatBytes(track.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(track.trackNumber)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("review_new_tracks_title", value: "New Tracks", comment: "Review new tracks title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("cancel_button", comment: "Cancel")) { onCancel() }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

