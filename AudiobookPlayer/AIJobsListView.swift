import SwiftUI

struct AIJobsListView: View {
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @State private var selectedJobForDetail: AIGenerationJob?

    var body: some View {
        List {
            if !aiGenerationManager.activeJobs.isEmpty {
                Section(header: Text("Active Jobs")) {
                    ForEach(aiGenerationManager.activeJobs) { job in
                        AIJobCardView(job: job, showDeleteButton: false)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onTapGesture {
                                selectedJobForDetail = job
                            }
                    }
                }
            }

            if !aiJobHistory.isEmpty {
                Section(header: Text("History")) {
                    ForEach(aiJobHistory) { job in
                        AIJobCardView(job: job, showDeleteButton: false)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onTapGesture {
                                selectedJobForDetail = job
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        await aiGenerationManager.deleteJob(job)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            
            if aiGenerationManager.activeJobs.isEmpty && aiJobHistory.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No AI Jobs")
                            .font(.headline)
                        Text("Your AI generation tasks will appear here.")
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
        .navigationTitle(NSLocalizedString("ai_tab_jobs_section", comment: "AI Jobs"))
        .sheet(item: $selectedJobForDetail) { job in
            AIGenerationJobDetailView(jobId: job.id)
        }
    }

    private var aiJobHistory: [AIGenerationJob] {
        Array(aiGenerationManager.recentJobs.filter { $0.isTerminal }.prefix(20))
    }
}

// MARK: - Modern Card View
struct AIJobCardView: View {
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    let job: AIGenerationJob
    let showDeleteButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with title and status
            HStack(alignment: .top, spacing: 12) {
                // Icon based on job type
                Image(systemName: jobIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor.opacity(0.8))
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(jobTitle(for: job))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                AIJobStatusBadge(status: job.status)
            }
            .padding(16)
            
            // Content preview
            if let detail = jobDetail(for: job), !detail.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(statusColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var jobIcon: String {
        switch job.type {
        case .chatTester: return "bubble.left.and.bubble.right"
        case .transcriptRepair: return "waveform.badge.magnifyingglass"
        case .trackSummary: return "doc.text.magnifyingglass"
        }
    }
    
    private var statusColor: Color {
        switch job.status {
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .gray
        default: return .blue
        }
    }

    private func jobTitle(for job: AIGenerationJob) -> String {
        switch job.type {
        case .chatTester:
            return NSLocalizedString("ai_job_type_chat_tester", comment: "")
        case .transcriptRepair:
            return job.displayName ?? NSLocalizedString("ai_job_type_transcript_repair", comment: "")
        case .trackSummary:
            return job.displayName ?? NSLocalizedString("ai_job_type_track_summary", comment: "")
        }
    }

    private func jobDetail(for job: AIGenerationJob) -> String? {
        switch job.type {
        case .chatTester:
            if let output = job.streamedOutput ?? job.finalOutput, !output.isEmpty {
                return output
            }
            if let prompt = job.userPrompt, !prompt.isEmpty {
                return prompt
            }
            return nil
        case .transcriptRepair:
            if let results = job.decodedMetadata()?.repairResults {
                if results.isEmpty {
                    return "No changes."
                }
                return "Updated \(results.count) segment(s)."
            }
            if let payload = job.decodedPayload(TranscriptRepairJobPayload.self) {
                return "Queued \(payload.selectionIndexes.count) segment(s)."
            }
            return nil
        case .trackSummary:
            return job.finalOutput
        }
    }
}

// MARK: - Status Badge
struct AIJobStatusBadge: View {
    let status: AIGenerationJob.Status
    
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
        case .queued: return "clock.fill"
        case .running, .streaming: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .canceled: return "xmark.circle.fill"
        }
    }
    
    var statusText: String {
        switch status {
        case .queued: return NSLocalizedString("ai_job_status_queued", comment: "")
        case .running, .streaming: return NSLocalizedString("ai_job_status_running", comment: "")
        case .completed: return NSLocalizedString("ai_job_status_completed", comment: "")
        case .failed: return NSLocalizedString("ai_job_status_failed", comment: "")
        case .canceled: return NSLocalizedString("ai_job_status_canceled", comment: "")
        }
    }
    
    var statusColor: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .gray
        case .queued: return .orange
        default: return .blue
        }
    }
}
