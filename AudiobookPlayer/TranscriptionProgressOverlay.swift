import SwiftUI

// MARK: - Transcription Progress Overlay

/// Global HUD for displaying active transcription jobs
/// Shows as a badge/pill when transcriptions are in progress
struct TranscriptionProgressOverlay: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @State private var showProgressSheet = false
    @State private var activeJobs: [(trackId: String, trackName: String, progress: Double)] = []

    var body: some View {
        Group {
            if transcriptionManager.isTranscribing, let trackId = transcriptionManager.currentTrackId {
                VStack(spacing: 0) {
                    // Progress badge
                    Button(action: { showProgressSheet = true }) {
                        HStack(spacing: 8) {
                            ProgressView(value: transcriptionManager.transcriptionProgress, total: 1.0)
                                .frame(width: 16, height: 16)

                            Text("transcribing_indicator")
                                .font(.caption)
                                .lineLimit(1)

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
    @State private var refreshTimer: Timer?

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("active_transcriptions")) {
                    if transcriptionManager.isTranscribing {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ProgressView(value: transcriptionManager.transcriptionProgress, total: 1.0)
                                    .frame(height: 8)

                                Text(String(format: "%.0f%%", transcriptionManager.transcriptionProgress * 100))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "waveform.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.headline)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("transcription_in_progress")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)

                                    Text("transcription_processing_message")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    StatusBadge(status: "transcribing")

                                    Text(statusTimeEstimate)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text("no_active_transcriptions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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

    private var statusTimeEstimate: String {
        let progress = transcriptionManager.transcriptionProgress
        if progress <= 0 || progress >= 1 {
            return ""
        }

        // Estimate remaining time (rough approximation)
        let estimatedTotalSeconds = 30.0  // Assume 30 seconds for a typical transcription
        let elapsedSeconds = progress * estimatedTotalSeconds
        let remainingSeconds = estimatedTotalSeconds - elapsedSeconds

        if remainingSeconds > 60 {
            let minutes = Int(remainingSeconds / 60)
            return String(format: "~%d min", minutes)
        } else {
            return String(format: "~%d sec", Int(remainingSeconds))
        }
    }

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
        case "uploading", "transcribing":
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
        case "uploading":
            return "uploading_status"
        case "transcribing":
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

// MARK: - Preview

#Preview {
    TranscriptionProgressOverlay()
        .environmentObject(TranscriptionManager())
}
