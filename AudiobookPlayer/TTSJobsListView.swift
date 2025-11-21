import SwiftUI

struct TTSJobsListView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedJobForTranscript: TranscriptionJob?

    var body: some View {
        List {
            if !transcriptionManager.activeJobs.isEmpty {
                Section(header: Text("Active Jobs")) {
                    ForEach(transcriptionManager.activeJobs) { job in
                        TTSJobCardView(job: job)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if job.isRunning {
                                    Button(action: { pauseJob(job) }) {
                                        Label(NSLocalizedString("tts_jobs_action_pause", comment: ""), systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                } else if job.status == "paused" {
                                    Button(action: { resumeJob(job) }) {
                                        Label(NSLocalizedString("tts_jobs_action_continue", comment: ""), systemImage: "play.fill")
                                    }
                                    .tint(.blue)
                                }

                                Button(role: .destructive, action: { deleteJob(job) }) {
                                    Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                }
                            }
                    }
                }
            }

            let historyJobs = transcriptionManager.allRecentJobs.filter { $0.status == "completed" || $0.status == "failed" }
            if !historyJobs.isEmpty {
                Section(header: Text("History")) {
                    ForEach(historyJobs) { job in
                        TTSJobCardView(job: job)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onTapGesture {
                                if job.status == "completed" {
                                    selectedJobForTranscript = job
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if job.status == "failed" {
                                    Button {
                                        retryJob(job)
                                    } label: {
                                        Label(NSLocalizedString("tts_jobs_action_retry", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .tint(.blue)
                                }
                                
                                Button(role: .destructive) {
                                    deleteJob(job)
                                } label: {
                                    Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                }
                            }
                    }
                }
            }
            
            if transcriptionManager.activeJobs.isEmpty && historyJobs.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Transcription Jobs")
                            .font(.headline)
                        Text("Your transcription tasks will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(NSLocalizedString("tts_jobs_history_title", comment: "Transcription Jobs"))
        .sheet(item: $selectedJobForTranscript) { job in
            TranscriptViewerSheet(
                trackId: job.trackId,
                trackName: lookupTrackName(for: job.trackId)
            )
        }
    }
    
    private func lookupTrackName(for trackId: String) -> String {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return track.displayName
            }
        }
        return trackId
    }
    
    private func pauseJob(_ job: TranscriptionJob) {
        Task {
            try? await transcriptionManager.pauseJob(jobId: job.id)
        }
    }

    private func resumeJob(_ job: TranscriptionJob) {
        Task {
            try? await transcriptionManager.resumeJob(jobId: job.id)
        }
    }

    private func retryJob(_ job: TranscriptionJob) {
        Task {
            try? await transcriptionManager.retryJob(jobId: job.id)
        }
    }

    private func deleteJob(_ job: TranscriptionJob) {
        Task {
            try? await transcriptionManager.deleteJob(jobId: job.id)
        }
    }
}

struct TTSJobCardView: View {
    @EnvironmentObject private var library: LibraryStore
    let job: TranscriptionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and status
            HStack(alignment: .top, spacing: 12) {
                // Icon based on job status
                statusIcon(for: job.status)
                    .font(.title3)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(lookupTrackName(for: job.trackId))
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    Text(formatDate(job.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                TTSJobStatusBadge(status: job.status)
            }
            .padding(16)
            
            // Progress bar for active jobs
            if (job.status == "downloading" || job.status == "uploading" || job.status == "transcribing" || job.status == "processing"), let progress = job.progress {
                Divider()
                    .padding(.horizontal, 16)
                
                VStack(spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(statusText(for: job))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            } else if job.status == "failed", let errorMessage = job.errorMessage {
                Divider()
                    .padding(.horizontal, 16)
                
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(statusColor(for: job.status).opacity(0.2), lineWidth: 1)
        )
    }
    
    private func lookupTrackName(for trackId: String) -> String {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return track.displayName
            }
        }
        return trackId
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func statusText(for job: TranscriptionJob) -> String {
        switch job.status {
        case "queued": return "Queued"
        case "downloading": return NSLocalizedString("status_downloading_audio", comment: "")
        case "uploading": return NSLocalizedString("status_uploading_audio", comment: "")
        case "transcribing", "processing": return "Transcribing..."
        case "completed": return "Completed"
        case "failed": return "Failed (retry \(job.retryCount))"
        case "paused": return NSLocalizedString("tts_jobs_status_paused", comment: "")
        default: return job.status.capitalized
        }
    }
    
    private func statusColor(for status: String) -> Color {
        switch status {
        case "queued": return .orange
        case "downloading", "uploading", "transcribing", "processing": return .blue
        case "completed": return .green
        case "failed": return .red
        case "paused": return .gray
        default: return .secondary
        }
    }
    
    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status {
        case "queued":
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case "downloading", "uploading", "transcribing", "processing":
            Image(systemName: "waveform")
                .foregroundStyle(.blue)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case "paused":
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        default:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

struct TTSJobStatusBadge: View {
    let status: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.caption2)
            Text(statusText)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.15))
        )
        .foregroundStyle(statusColor)
    }
    
    var statusIcon: String {
        switch status {
        case "queued": return "clock.fill"
        case "downloading", "uploading", "transcribing", "processing": return "arrow.triangle.2.circlepath"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "paused": return "pause.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    
    var statusText: String {
        switch status {
        case "queued": return "Queued"
        case "downloading", "uploading", "transcribing", "processing": return "Running"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "paused": return "Paused"
        default: return status.capitalized
        }
    }
    
    var statusColor: Color {
        switch status {
        case "queued": return .orange
        case "downloading", "uploading", "transcribing", "processing": return .blue
        case "completed": return .green
        case "failed": return .red
        case "paused": return .gray
        default: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        TTSJobsListView()
            .environmentObject(TranscriptionManager.preview)
            .environmentObject(LibraryStore.preview)
    }
}
