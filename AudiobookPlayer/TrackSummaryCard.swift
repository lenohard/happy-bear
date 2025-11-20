import SwiftUI
import Foundation

struct TrackSummaryCard: View {
    let track: AudiobookTrack
    let isTranscriptAvailable: Bool
    @ObservedObject var viewModel: TrackSummaryViewModel
    var seekAndPlayAction: (TimeInterval) -> Void

    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @State private var actionError: String?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                Divider()
                    .padding(.vertical, 4)
                content
            } else if let preview = collapsedPreviewText() {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .onChange(of: viewModel.activeJob?.status) { _ in
            actionError = nil
        }
        .onChange(of: viewModel.summary?.id) { _ in
            if !viewModel.hasSummaryContent() {
                isExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if canCollapseSummary {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Label(NSLocalizedString("track_summary_card_title", comment: "Track summary card title"), systemImage: "text.book.closed")
                            .font(.headline)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("track_summary_toggle_accessibility", comment: "Toggle track summary visibility"))
                .accessibilityValue(isExpanded ? NSLocalizedString("expanded_accessibility_label", comment: "") : NSLocalizedString("collapsed_accessibility_label", comment: ""))
            } else {
                Label(NSLocalizedString("track_summary_card_title", comment: "Track summary card title"), systemImage: "text.book.closed")
                    .font(.headline)
            }

            Spacer()

            if viewModel.hasSummaryContent() && isTranscriptAvailable && aiGateway.hasValidKey {
                Button(NSLocalizedString("track_summary_regenerate_button", comment: "Regenerate summary button")) {
                    Task { await triggerGeneration() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.activeJob?.isActive == true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isTranscriptAvailable {
            Text(NSLocalizedString("track_summary_requires_transcript", comment: "Track summary requires transcript message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if !aiGateway.hasValidKey {
            Text(NSLocalizedString("track_summary_missing_key_hint", comment: "Track summary missing key message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let job = viewModel.activeJob, job.isActive {
            jobInProgressView(job)
        } else if viewModel.status == .failed {
            failureView
            if let summary = viewModel.summary, summary.isReady {
                summaryView(summary)
            }
        } else if viewModel.hasSummaryContent(), let summary = viewModel.summary {
            summaryView(summary)
        } else {
            idleView
        }

        if let actionError {
            Text(actionError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("track_summary_generate_cta", comment: "Track summary description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let statsText = transcriptStatsText() {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(NSLocalizedString("track_summary_generate_button", comment: "Generate summary button")) {
                Task { await triggerGeneration() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeJob?.isActive == true)
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.errorMessage ?? NSLocalizedString("track_summary_generic_error", comment: "Generic summary error message"))
                .font(.subheadline)
                .foregroundStyle(.primary)

            if let statsText = transcriptStatsText() {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(NSLocalizedString("track_summary_retry_button", comment: "Retry summary generation button")) {
                    Task { await triggerGeneration() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.activeJob?.isActive == true)

                if let summary = viewModel.summary, summary.isReady {
                    Button(NSLocalizedString("track_summary_regenerate_button", comment: "Regenerate summary button")) {
                        Task { await triggerGeneration() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.activeJob?.isActive == true)
                }
            }
        }
    }

    private func summaryView(_ summary: TrackSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.summaryTitle ?? track.displayName)
                    .font(.headline)
                if let body = summary.summaryBody {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let generatedAt = summary.generatedAt {
                    Text(String(format: NSLocalizedString("track_summary_last_generated_format", comment: ""), generatedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !summary.keywords.isEmpty {
                keywordRow(summary.keywords)
            }

            if !viewModel.sections.isEmpty {
                Text(NSLocalizedString("track_summary_sections_header", comment: "Track summary sections header"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                VStack(spacing: 8) {
                    ForEach(viewModel.sections) { section in
                        sectionRow(section)
                    }
                }
            }
        }
    }

    private func jobInProgressView(_ job: AIGenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(jobStatusLabel(for: job))
                    .font(.subheadline)
                    .bold()
            }

            if let streamed = job.streamedOutput, !streamed.isEmpty {
                Text(streamed)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else if let display = job.displayName {
                Text(display)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionRow(_ section: TrackSummarySection) -> some View {
        Button {
            let seconds = TimeInterval(section.startTimeMs) / 1000.0
            seekAndPlayAction(seconds)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(section.startTimeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    if let title = section.title {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
                Text(section.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !section.keywords.isEmpty {
                    keywordRow(section.keywords)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    private func keywordRow(_ keywords: [String]) -> some View {
        HStack(spacing: 6) {
            Text(NSLocalizedString("track_summary_keywords_label", comment: "Keywords label"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Array(keywords.prefix(4)), id: \.self) { keyword in
                Text(keyword)
                    .font(.caption2)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(uiColor: .secondarySystemFill))
                    )
            }
        }
    }

    private func jobStatusLabel(for job: AIGenerationJob) -> String {
        switch job.status {
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

    private func transcriptStatsText() -> String? {
        guard isTranscriptAvailable else { return nil }
        guard !viewModel.hasSummaryContent() else { return nil }
        guard let stats = viewModel.transcriptStats else { return nil }

        let segmentCount = formattedNumber(stats.segmentCount)
        let characterCount = formattedNumber(stats.characterCount)

        return String(
            format: NSLocalizedString("track_summary_transcript_stats", comment: "Transcript stats shown in idle state"),
            segmentCount,
            characterCount
        )
    }

    private func collapsedPreviewText() -> String? {
        if let summary = viewModel.summary {
            if let body = summary.summaryBody, !body.isEmpty {
                return body
            }
            if let title = summary.summaryTitle, !title.isEmpty {
                return title
            }
        }
        return transcriptStatsText()
    }

    private var canCollapseSummary: Bool {
        viewModel.hasSummaryContent()
    }

    private func formattedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func triggerGeneration() async {
        guard isTranscriptAvailable else {
            actionError = NSLocalizedString("track_summary_requires_transcript", comment: "")
            return
        }
        guard aiGateway.hasValidKey else {
            actionError = NSLocalizedString("track_summary_missing_key_hint", comment: "")
            return
        }

        actionError = nil
        do {
            try await viewModel.startGeneration(
                using: aiGenerationManager,
                modelId: aiGateway.selectedModelID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }
}
