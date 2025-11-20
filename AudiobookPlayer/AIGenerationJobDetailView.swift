import SwiftUI

struct AIGenerationJobDetailView: View {
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @Environment(\.dismiss) private var dismiss

    let jobId: String

    private var job: AIGenerationJob? {
        aiGenerationManager.job(withId: jobId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let job {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            jobHeader(job)
                            outputSection(for: job)
                            reasoningSection(for: job)

                            if job.systemPrompt != nil || job.userPrompt != nil {
                                promptsSection(for: job)
                            }

                            if let metadata = job.decodedMetadata(), !metadata.flagsOrExtrasSummary.isEmpty {
                                metadataSection(summary: metadata.flagsOrExtrasSummary)
                            }

                            if let usage = job.decodedUsage() {
                                usageSection(usage)
                            }

                            if let error = job.errorMessage, !error.isEmpty {
                                errorSection(error)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("ai_job_detail_missing", comment: "Missing job message"))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
                }
            }
            .navigationTitle(Text(NSLocalizedString("ai_job_detail_title", comment: "AI job detail title")))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("done_button", comment: "Done button")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func jobHeader(_ job: AIGenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(jobTitle(for: job))
                .font(.title3)
                .bold()

            HStack(spacing: 8) {
                Label(localizedStatus(for: job.status), systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(statusColor(for: job))
                    .font(.caption)
                Text("\(NSLocalizedString("ai_job_detail_type_label", comment: "")): \(jobTypeDescription(for: job))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let model = job.modelId {
                    Text("\(NSLocalizedString("ai_job_detail_model_label", comment: "")): \(model)")
                        .font(.subheadline)
                }
                Text("\(NSLocalizedString("ai_job_detail_created_label", comment: "")): \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let completed = job.completedAt {
                    Text("\(NSLocalizedString("ai_job_detail_completed_label", comment: "")): \(completed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func outputSection(for job: AIGenerationJob) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_output_header", comment: ""), systemImage: "text.justify")) {
            if let output = job.streamedOutput ?? job.finalOutput, !output.isEmpty {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(NSLocalizedString("ai_job_detail_no_output", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reasoningSection(for job: AIGenerationJob) -> some View {
        if
            let reasoning = job.decodedMetadata()?.reasoning,
            let text = reasoning.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            reasoningDetailsSection(reasoning: reasoning, hasText: true)
        } else if let reasoning = job.decodedMetadata()?.reasoning,
                  let details = reasoning.details,
                  !details.isEmpty
        {
            reasoningDetailsSection(reasoning: reasoning, hasText: false)
        } else {
            EmptyView()
        }
    }

    private func reasoningDetailsSection(reasoning: AIGenerationReasoningSnapshot, hasText: Bool) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_reasoning_header", comment: ""), systemImage: "brain.head.profile")) {
            VStack(alignment: .leading, spacing: 8) {
                if hasText, let text = reasoning.text {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let details = reasoning.details, !details.isEmpty {
                    ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let summary = detail.summary, !summary.isEmpty {
                                Text(summary)
                                    .textSelection(.enabled)
                            } else if let text = detail.text, !text.isEmpty {
                                Text(text)
                                    .textSelection(.enabled)
                            } else if let data = detail.data, !data.isEmpty {
                                Text(data)
                                    .textSelection(.enabled)
                            }
                            if let format = detail.format, !format.isEmpty {
                                Text(format)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let signature = detail.signature, !signature.isEmpty {
                                Text(signature)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, index == 0 ? 0 : 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func promptsSection(for job: AIGenerationJob) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_prompts_header", comment: ""), systemImage: "quote.bubble")) {
            VStack(alignment: .leading, spacing: 12) {
                if let system = job.systemPrompt, !system.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("ai_job_detail_system_prompt", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(system)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let user = job.userPrompt, !user.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("ai_job_detail_user_prompt", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(user)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func metadataSection(summary: String) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_metadata_header", comment: ""), systemImage: "info.circle")) {
            Text(summary)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }

    private func usageSection(_ usage: AIGenerationUsageSnapshot) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_usage_header", comment: ""), systemImage: "chart.bar")) {
            VStack(alignment: .leading, spacing: 4) {
                if let total = usage.totalTokens {
                    Text(String(format: NSLocalizedString("ai_job_detail_usage_total", comment: ""), total))
                }
                if let prompt = usage.promptTokens {
                    Text(String(format: NSLocalizedString("ai_job_detail_usage_prompt", comment: ""), prompt))
                }
                if let completion = usage.completionTokens {
                    Text(String(format: NSLocalizedString("ai_job_detail_usage_completion", comment: ""), completion))
                }
                if let cost = usage.cost {
                    Text(String(format: NSLocalizedString("ai_job_detail_usage_cost", comment: ""), cost))
                }
                if let reasoning = usage.reasoningTokens {
                    Text(
                        String(
                            format: NSLocalizedString("ai_job_detail_usage_reasoning", comment: ""),
                            reasoning
                        )
                    )
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func errorSection(_ error: String) -> some View {
        GroupBox(label: Label(NSLocalizedString("ai_job_detail_error_header", comment: ""), systemImage: "exclamationmark.triangle")) {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
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

    private func jobTypeDescription(for job: AIGenerationJob) -> String {
        switch job.type {
        case .chatTester:
            return NSLocalizedString("ai_job_type_chat_tester", comment: "")
        case .transcriptRepair:
            return NSLocalizedString("ai_job_type_transcript_repair", comment: "")
        case .trackSummary:
            return NSLocalizedString("ai_job_type_track_summary", comment: "")
        }
    }

    private func localizedStatus(for status: AIGenerationJob.Status) -> String {
        switch status {
        case .queued:
            return NSLocalizedString("ai_job_status_queued", comment: "")
        case .running, .streaming:
            return NSLocalizedString("ai_job_status_running", comment: "")
        case .completed:
            return NSLocalizedString("ai_job_status_completed", comment: "")
        case .failed:
            return NSLocalizedString("ai_job_status_failed", comment: "")
        case .canceled:
            return NSLocalizedString("ai_job_status_canceled", comment: "")
        }
    }

    private func statusColor(for job: AIGenerationJob) -> Color {
        switch job.status {
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .gray
        default:
            return .orange
        }
    }
}

private extension AIGenerationJobMetadata {
    var flagsOrExtrasSummary: String {
        var parts: [String] = []
        if let flags, !flags.isEmpty {
            let flagSummary = flags
                .map { "\($0.key)=\($0.value ? "true" : "false")" }
                .sorted()
                .joined(separator: ", ")
            parts.append("Flags: \(flagSummary)")
        }
        if let extras, !extras.isEmpty {
            let extraSummary = extras
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            parts.append("Metadata: \(extraSummary)")
        }
        if let repairs = repairResults, !repairs.isEmpty {
            parts.append("Repairs: \(repairs.count)")
        }
        if let reasoning = reasoning,
           (reasoning.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ||
           !(reasoning.details?.isEmpty ?? true) {
            parts.append(NSLocalizedString("ai_job_detail_reasoning_summary", comment: ""))
        }
        return parts.joined(separator: "\n")
    }
}
