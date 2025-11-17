import SwiftUI

// MARK: - Transcription Progress Overlay

/// Global HUD for displaying active transcription jobs
/// Shows as a badge/pill when transcriptions are in progress
struct TranscriptionProgressOverlay: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @State private var showProgressSheet = false

    var body: some View {
        Group {
            if !transcriptionManager.activeJobs.isEmpty {
                VStack(spacing: 0) {
                    // Progress badge
                    Button(action: { showProgressSheet = true }) {
                        HStack(spacing: 8) {
                            ProgressView(value: aggregateProgress, total: 1.0)
                                .frame(width: 16, height: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("transcribing_indicator")
                                    .font(.caption)
                                    .lineLimit(1)

                                if let summary = overlaySummary {
                                    Text(summary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(16)
                        .foregroundStyle(.blue)
                    }
                    .padding(8)
                }
                .sheet(isPresented: $showProgressSheet) {
                    TranscriptionProgressSheet()
                }
            }
        }
    }
}

// MARK: - Progress Sheet Component

/// Detailed progress sheet showing all active transcription jobs
struct TranscriptionProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @State private var refreshTimer: Timer?

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("active_transcriptions")) {
                    if transcriptionManager.activeJobs.isEmpty {
                        Text("no_active_transcriptions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transcriptionManager.activeJobs) { job in
                            let trackName = lookupTrackName(for: job.trackId, in: library) ?? job.trackId
                            TranscriptionJobRowView(job: job, trackName: trackName)
                        }
                    }
                }

                if let errorMessage = transcriptionManager.errorMessage, !errorMessage.isEmpty {
                    Section(header: Text("recent_errors")) {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("transcription_error_occurred")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section(header: Text("tips")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)

                            Text("transcription_tip_background")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)

                            Text("transcription_tip_view")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("transcription_progress_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done_button") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
    }

    // MARK: - Private Methods

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Timer just triggers view updates, actual data comes from TranscriptionManager
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Status Badge Component

struct StatusBadge: View {
    let status: String

    var statusColor: Color {
        switch status {
        case "queued":
            return .gray
        case "downloading", "uploading":
            return .blue
        case "uploading", "transcribing", "processing":
            return .blue
        case "completed":
            return .green
        case "failed":
            return .red
        default:
            return .gray
        }
    }

    var statusLabel: String {
        switch status {
        case "queued":
            return "queued_status"
        case "downloading":
            return "downloading_status"
        case "uploading":
            return "uploading_status"
        case "transcribing", "processing":
            return "transcribing_status"
        case "completed":
            return "completed_status"
        case "failed":
            return "failed_status"
        default:
            return "unknown_status"
        }
    }

    var body: some View {
        Text(NSLocalizedString(statusLabel, comment: ""))
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .cornerRadius(6)
            .foregroundStyle(statusColor)
    }
}

// MARK: - Active Job Helpers

private extension TranscriptionProgressOverlay {
    var overlaySummary: String? {
        guard let firstJob = transcriptionManager.activeJobs.first else {
            return nil
        }
        if transcriptionManager.activeJobs.count == 1 {
            return lookupTrackName(for: firstJob.trackId, in: library) ?? firstJob.trackId
        }
        return "\(transcriptionManager.activeJobs.count)"
    }

    var aggregateProgress: Double {
        let jobs = transcriptionManager.activeJobs
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { partial, job in
            partial + (job.progress ?? 0)
        }
        return total / Double(jobs.count)
    }
}

@MainActor
private func lookupTrackName(for trackId: String, in library: LibraryStore) -> String? {
    guard let uuid = UUID(uuidString: trackId) else {
        return nil
    }

    for collection in library.collections {
        if let track = collection.tracks.first(where: { $0.id == uuid }) {
            return track.displayName
        }
    }

    return nil
}

struct TranscriptionJobRowView: View {
    let job: TranscriptionJob
    let trackName: String

    private var progressValue: Double {
        min(max(job.progress ?? 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trackName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    Text(job.sonioxJobId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                StatusBadge(status: job.status)
            }

            ProgressView(value: progressValue, total: 1.0)
                .progressViewStyle(.linear)

            HStack {
                Text(String(format: "%.0f%%", progressValue * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(job.status.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Preview

#Preview {
    TranscriptionProgressOverlay()
        .environmentObject(TranscriptionManager())
        .environmentObject(LibraryStore())
}
