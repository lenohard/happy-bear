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
                Section {
                    if transcriptionManager.activeJobs.isEmpty {
                        Text("no_active_transcriptions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(transcriptionManager.activeJobs) { job in
                            let trackName = lookupTrackName(for: job.trackId, in: library) ?? job.trackId
                            TranscriptionJobRowView(job: job, trackName: trackName)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                } header: {
                    Text("active_transcriptions")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 4)
                }
                .listSectionSeparator(.hidden)

                if let errorMessage = transcriptionManager.errorMessage, !errorMessage.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("transcription_error_occurred")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(16)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("recent_errors")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.subheadline)

                            Text("transcription_tip_background")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.subheadline)

                            Text("transcription_tip_view")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("tips")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
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
        case "extracting":
            return .orange
        case "generating", "transcribing", "processing":
            return .purple
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
        case "extracting":
            return "extracting_status"
        case "uploading":
            return "uploading_status"
        case "generating":
            return "tts_generating_audio"
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
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.15))
            .cornerRadius(8)
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
    
    private var isTTSJob: Bool { job.sonioxJobId.hasPrefix("tts-") }
    
    private var detailStatusText: String {
        switch job.status {
        case "queued":
            return NSLocalizedString("queued_status", comment: "")
        case "downloading":
            return NSLocalizedString("downloading_status", comment: "")
        case "extracting":
            return NSLocalizedString("extracting_status", comment: "")
        case "uploading":
            return NSLocalizedString("uploading_status", comment: "")
        case "transcribing", "processing", "generating":
            if isTTSJob {
                if let processed = job.processedParagraphs, let total = job.totalParagraphs, total > 0 {
                    return String(format: NSLocalizedString("tts_generating_paragraph_progress", comment: ""), processed, total)
                } else {
                    return NSLocalizedString("tts_generating_audio", comment: "")
                }
            } else {
                return NSLocalizedString("transcribing_status", comment: "")
            }
        case "completed":
            return NSLocalizedString("completed_status", comment: "")
        case "failed":
            return NSLocalizedString("failed_status", comment: "")
        case "paused":
            return NSLocalizedString("tts_jobs_status_paused", comment: "")
        default:
            return job.status.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                // Icon Container
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 42, height: 42)
                    
                    Image(systemName: isTTSJob ? "text.bubble.fill" : "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(trackName)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        StatusBadge(status: job.status)
                    }
                    
                    Text("ID: " + job.sonioxJobId)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(spacing: 6) {
                HStack {
                    Text(detailStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text(String(format: "%.0f%%", progressValue * 100))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 6)
                        
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(geo.size.width * CGFloat(progressValue), 6), height: 6)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: progressValue)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.1))
                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    TranscriptionProgressOverlay()
        .environmentObject(TranscriptionManager())
        .environmentObject(LibraryStore())
}
