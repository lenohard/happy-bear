import SwiftUI

struct TTSJobsListView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playerViewModel: AudioPlayerViewModel
    @State private var selectedJobForTranscript: TranscriptionJob?

    // Filter to show only TTS jobs (not STT jobs)
    // Active jobs: non-terminal states (not completed, not failed)
    private var ttsActiveJobs: [TranscriptionJob] {
        transcriptionManager.activeJobs.filter { $0.sonioxJobId.hasPrefix("tts-") }
    }

    // History jobs: terminal states only (completed or failed)
    // Exclude jobs that are already in activeJobs to prevent duplicates
    private var ttsHistoryJobs: [TranscriptionJob] {
        let activeJobIds = Set(ttsActiveJobs.map(\.id))
        return transcriptionManager.allRecentJobs.filter {
            $0.sonioxJobId.hasPrefix("tts-") &&
            ($0.status == "completed" || $0.status == "failed") &&
            !activeJobIds.contains($0.id)
        }
    }

    var body: some View {
        List {
            if !ttsActiveJobs.isEmpty {
                Section(header: Text("Active Jobs")) {
                    ForEach(ttsActiveJobs) { job in
                        TTSJobCardView(job: job)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if job.isRunning {
                                    Button(action: { pauseJob(job) }) {
                                        Label(NSLocalizedString("tts_jobs_action_pause", comment: ""), systemImage: "pause.fill")
                                    }
                                    .labelStyle(.iconOnly)
                                    .tint(.orange)
                                } else if job.status == "paused" {
                                    Button(action: { resumeJob(job) }) {
                                        Label(NSLocalizedString("tts_jobs_action_continue", comment: ""), systemImage: "play.fill")
                                    }
                                    .labelStyle(.iconOnly)
                                    .tint(.blue)
                                }

                                Button(role: .destructive, action: { deleteJob(job) }) {
                                    Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }
                    }
                }
            }

            if !ttsHistoryJobs.isEmpty {
                Section(header: Text("History")) {
                    ForEach(ttsHistoryJobs) { job in
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
                                    .labelStyle(.iconOnly)
                                    .tint(.blue)
                                }
                                
                                Button(role: .destructive) {
                                    deleteJob(job)
                                } label: {
                                    Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }
                    }
                }
            }
            
            if ttsActiveJobs.isEmpty && ttsHistoryJobs.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No TTS Jobs")
                            .font(.headline)
                        Text("Your text-to-speech generation tasks will appear here.")
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
        .navigationTitle("TTS Jobs")
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
            // For TTS jobs, pause means mark as paused in DB
            // The running Task in AudioPlayerViewModel will continue but the job won't be resumed automatically
            try? await transcriptionManager.pauseJob(jobId: job.id)
            // pauseJob already calls refreshActiveJobsFromDatabase + refreshAllRecentJobs
        }
    }

    private func resumeJob(_ job: TranscriptionJob) {
        Task {
            // Use AudioPlayerViewModel's resumeTTSJob for TTS jobs
            do {
                try await playerViewModel.resumeTTSJob(jobId: job.id)
                // Refresh to show updated status
                await transcriptionManager.refreshActiveJobsFromDatabase()
                await transcriptionManager.refreshAllRecentJobs()
            } catch {
                AppLog.debug("[TTS] Failed to resume job: \(error.localizedDescription)")
                // Refresh even on error to show current state
                await transcriptionManager.refreshActiveJobsFromDatabase()
                await transcriptionManager.refreshAllRecentJobs()
            }
        }
    }

    private func retryJob(_ job: TranscriptionJob) {
        Task {
            // Use AudioPlayerViewModel's resumeTTSJob for TTS jobs (retry is same as resume)
            do {
                try await playerViewModel.resumeTTSJob(jobId: job.id)
                // Refresh to show updated status
                await transcriptionManager.refreshActiveJobsFromDatabase()
                await transcriptionManager.refreshAllRecentJobs()
            } catch {
                AppLog.debug("[TTS] Failed to retry job: \(error.localizedDescription)")
                // Refresh even on error to show current state
                await transcriptionManager.refreshActiveJobsFromDatabase()
                await transcriptionManager.refreshAllRecentJobs()
            }
        }
    }

    private func deleteJob(_ job: TranscriptionJob) {
        Task {
            try? await transcriptionManager.deleteJob(jobId: job.id)
            // deleteJob already calls refresh internally
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
            if (["downloading", "uploading", "transcribing", "processing", "generating"]).contains(job.status), let progress = job.progress {
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
        // Check if this is a TTS job (sonioxJobId starts with "tts-")
        let isTTSJob = job.sonioxJobId.hasPrefix("tts-")
        
        switch job.status {
        case "queued": return NSLocalizedString("queued_status", comment: "")
        case "downloading": return NSLocalizedString("status_downloading_audio", comment: "")
        case "uploading": return NSLocalizedString("status_uploading_audio", comment: "")
        case "generating", "transcribing", "processing":
            if isTTSJob {
                if let processed = job.processedParagraphs, let total = job.totalParagraphs {
                    return String(format: NSLocalizedString("tts_generating_paragraph_progress", comment: ""), processed, total)
                } else {
                    return NSLocalizedString("tts_generating_audio", comment: "")
                }
            } else {
                return NSLocalizedString("transcribing_status", comment: "")
            }
        case "completed": return NSLocalizedString("completed_status", comment: "")
        case "failed": return "Failed (retry \(job.retryCount))"
        case "paused": return NSLocalizedString("tts_jobs_status_paused", comment: "")
        default: return job.status.capitalized
        }
    }
    
    private func statusColor(for status: String) -> Color {
        switch status {
        case "queued": return .orange
        case "downloading", "uploading", "transcribing", "processing", "generating": return .blue
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
        case "downloading", "uploading", "transcribing", "processing", "generating":
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
        case "downloading", "uploading", "transcribing", "processing", "generating": return "arrow.triangle.2.circlepath"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "paused": return "pause.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    
    var statusText: String {
        switch status {
        case "queued":
            return NSLocalizedString("queued_status", comment: "")
        case "downloading", "uploading", "transcribing", "processing", "generating":
            return NSLocalizedString("tts_job_status_running", comment: "Active TTS job label")
        case "completed":
            return NSLocalizedString("completed_status", comment: "")
        case "failed":
            return NSLocalizedString("failed_status", comment: "")
        case "paused":
            return NSLocalizedString("tts_jobs_status_paused", comment: "")
        default: return status.capitalized
        }
    }
    
    var statusColor: Color {
        switch status {
        case "queued": return .orange
        case "downloading", "uploading", "transcribing", "processing", "generating": return .blue
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
