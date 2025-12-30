import SwiftUI
import Foundation

/// Caches and sanitizes track HTML descriptions so we don't re-parse on every SwiftUI update.
private actor TrackDescriptionSanitizer {
    static let shared = TrackDescriptionSanitizer()

    private var cache: [String: String] = [:]

    /// Returns a plain-text description, or nil if the sanitized text is empty.
    func sanitizedDescription(from raw: String) -> String? {
        if let cached = cache[raw] {
            return cached.isEmpty ? nil : cached
        }

        let sanitized = Self.sanitizeHTML(raw)
        cache[raw] = sanitized ?? ""
        return sanitized
    }

    nonisolated private static func sanitizeHTML(_ raw: String) -> String? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return nil }
        // Cheap strip: preserve paragraph breaks and remove tags.
        var intermediate = trimmedRaw
        intermediate = intermediate.replacingOccurrences(
            of: "(?i)<br ?/?>",
            with: "\n",
            options: .regularExpression
        )
        intermediate = intermediate.replacingOccurrences(
            of: "(?i)</p>",
            with: "\n\n",
            options: .regularExpression
        )
        let stripped = intermediate.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Minimal entity decode for common cases.
        let decoded = stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        let collapsed = decoded
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return collapsed.isEmpty ? nil : collapsed
    }
}

struct TrackSummaryCard: View {
    let track: AudiobookTrack
    let isTranscriptAvailable: Bool
    @ObservedObject var viewModel: TrackSummaryViewModel
    var seekAndPlayAction: (TimeInterval) -> Void
    var onRequestTranscription: (() -> Void)? = nil
    var onRequestTranslations: (() -> Void)? = nil
    var isReadOnly: Bool = false

    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @AppStorage("remoteJobsEnabled") private var remoteJobsEnabled = false
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var actionError: String?
    @State private var isExpanded = false
    @State private var hasAnimatedExpansion = false
    @State private var didInitializeExpansion = false
    @State private var sanitizedDescriptionText: String?

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
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(themeManager.colors.isFestive ? themeManager.colors.background : Color(uiColor: .secondarySystemBackground))
        )
        .onChange(of: viewModel.activeJob?.status) {
            actionError = nil
        }
        .onChange(of: viewModel.summary?.id) {
            handleSummaryContentChange()
        }
        .task {
            initializeExpansionState()
        }
        .task(id: rawDescription) {
            await refreshSanitizedDescription()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if canCollapseSummary {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                    hasAnimatedExpansion = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.primary : Color.accentColor)
                        Label(NSLocalizedString("track_summary_card_title", comment: "Track summary card title"), systemImage: "text.book.closed")
                            .font(.headline)
                            .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.primary : .primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("track_summary_toggle_accessibility", comment: "Toggle track summary visibility"))
                .accessibilityValue(isExpanded ? NSLocalizedString("expanded_accessibility_label", comment: "") : NSLocalizedString("collapsed_accessibility_label", comment: ""))
            } else {
                Label(NSLocalizedString("track_summary_card_title", comment: "Track summary card title"), systemImage: "text.book.closed")
                    .font(.headline)
                    .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.primary : .primary)
            }

            Spacer()

            if shouldShowActionButton {
                if isActionInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Menu {
                        Button {
                            Task { await triggerGeneration() }
                        } label: {
                            Label(
                                NSLocalizedString("track_summary_generate_button", comment: "Generate summary button"),
                                systemImage: "text.badge.plus"
                            )
                        }

                        if let onRequestTranslations {
                            Button(action: onRequestTranslations) {
                                Label(
                                    NSLocalizedString("track_summary_translate_button", comment: "Generate translated summary button"),
                                    systemImage: "character.book.closed"
                                )
                            }
                            .accessibilityIdentifier("trackSummaryTranslateButton")
                        }
                    } label: {
                        Label(actionButtonTitle, systemImage: "sparkles")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.festiveGold : .accentColor)
                    }
                    .accessibilityIdentifier("trackSummaryActionMenu")
                    .menuStyle(.button)
                    .controlSize(.small)
                    .disabled(isActionDisabled)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isTranscriptAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("track_summary_requires_transcript", comment: "Track summary requires transcript message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if let onRequestTranscription, !isReadOnly {
                    Button {
                        onRequestTranscription()
                    } label: {
                        Label(NSLocalizedString("transcribe_track_title", comment: "Transcribe track title"), systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 12))
                }
            }
        } else if !hasAIBackend {
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

        if let description = sanitizedDescriptionText, !description.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("track_description_header", value: "Description", comment: "Track description header"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
        }

        if let actionError {
            Text(actionError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isReadOnly ? NSLocalizedString("No summary", comment: "") : NSLocalizedString("track_summary_generate_cta", comment: "Track summary description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let statsText = transcriptStatsText() {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

            if !summary.mentionedItems.isEmpty {
                mentionedItemsRow(summary.mentionedItems)
            }

        if !viewModel.sections.isEmpty {
            Text(NSLocalizedString("track_summary_sections_header", comment: "Track summary sections header"))
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVStack(spacing: 8) {
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
            
            if let streamedReasoning = job.streamedReasoning, !streamedReasoning.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Thinking...", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(streamedReasoning)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
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
                        .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.primary : Color.accentColor)
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
                    .fill(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground : Color(uiColor: .tertiarySystemFill))
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

    private func mentionedItemsRow(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(NSLocalizedString("track_summary_mentioned_items_label", value: "Mentioned", comment: "Mentioned items label"), systemImage: "bookmark")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func translationsView(_ translations: [TrackSummaryTranslation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                NSLocalizedString("track_summary_translations_header", value: "Lyric Translation", comment: "Translations header"),
                systemImage: "music.note.list"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LazyVStack(spacing: 6) {
                ForEach(translations) { translation in
                    translationRow(translation)
                }
            }
        }
    }

    private func translationRow(_ translation: TrackSummaryTranslation) -> some View {
        Button {
            let seconds = TimeInterval(translation.startTimeMs) / 1000.0
            seekAndPlayAction(seconds)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(translation.startTimeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Text(translation.translation)
                    .font(.footnote)
                    .foregroundStyle(.primary)
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
    
    private var rawDescription: String? {
        track.metadata["description"]
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

    private var shouldShowActionButton: Bool {
        !isReadOnly && isTranscriptAvailable && hasAIBackend
    }

    private var isActionInFlight: Bool {
        viewModel.isLoading || (viewModel.activeJob?.isActive == true)
    }

    private var isActionDisabled: Bool {
        isActionInFlight
    }

        private var actionButtonTitle: String {
            if viewModel.hasSummaryContent() {
                return NSLocalizedString("track_summary_regenerate_button", comment: "Regenerate summary button")
            } else {
                return NSLocalizedString("track_summary_generate_button", comment: "Generate summary button")
            }
        }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formattedNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    @MainActor
    private func refreshSanitizedDescription() async {
        sanitizedDescriptionText = nil
        guard let raw = rawDescription, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sanitizedDescriptionText = await TrackDescriptionSanitizer.shared.sanitizedDescription(from: raw)
    }

    private func triggerGeneration() async {
        guard isTranscriptAvailable else {
            actionError = NSLocalizedString("track_summary_requires_transcript", comment: "")
            return
        }
        guard hasAIBackend else {
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

    private var hasAIBackend: Bool {
        aiGateway.hasValidKey || remoteJobsEnabled
    }
}

private extension TrackSummaryCard {
    func initializeExpansionState() {
        guard !didInitializeExpansion else { return }
        didInitializeExpansion = true
        isExpanded = !viewModel.hasSummaryContent()
    }

    func handleSummaryContentChange() {
        let hasSummary = viewModel.hasSummaryContent()
        if hasSummary {
            guard !hasAnimatedExpansion else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = false
            }
        } else {
            hasAnimatedExpansion = false
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject private var viewModel = TrackSummaryViewModel()
        let trackId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        
        var body: some View {
            TrackSummaryCard(
                track: AudiobookTrack(
                    id: trackId,
                    displayName: "Preview Track",
                    filename: "preview.mp3",
                    location: .external(url: URL(string: "https://example.com")!),
                    fileSize: 1024,
                    duration: 300,
                    trackNumber: 1,
                    checksum: nil,
                    metadata: [:]
                ),
                isTranscriptAvailable: true,
                viewModel: viewModel,
                seekAndPlayAction: { _ in }
            )
            .environmentObject(AIGatewayViewModel())
            .environmentObject(AIGenerationManager())
            .padding()
            .task {
                // Inject Dummy Summary
                let dbManager = GRDBDatabaseManager.shared
                try? await dbManager.initializeDatabase()
                
                let sections = [
                    TrackSummarySection(
                        trackSummaryId: trackId.uuidString,
                        orderIndex: 0,
                        startTimeMs: 0,
                        endTimeMs: 30000,
                        title: "Section 1",
                        summary: "This is the first section summary.",
                        keywords: ["one", "first"]
                    ),
                    TrackSummarySection(
                        trackSummaryId: trackId.uuidString,
                        orderIndex: 1,
                        startTimeMs: 30000,
                        endTimeMs: 60000,
                        title: "Section 2",
                        summary: "This is the second section summary.",
                        keywords: ["two", "second"]
                    )
                ]
                
                try? await dbManager.persistTrackSummaryResult(
                    trackId: trackId.uuidString,
                    transcriptId: "preview-transcript-id",
                    language: "en",
                    summaryTitle: "Preview Summary",
                    summaryBody: "This is a preview summary body.",
                    keywords: ["preview", "test"],
                    mentionedItems: ["Sample Book", "Example Movie"],
                    suggestedCorrections: [
                        "Protagonist": "Spell the lead character name as 'Qian'",
                        "Setting": "Clarify that the scene occurs in 1980s Shanghai"
                    ],
                    sections: sections,
                    modelIdentifier: "preview-model",
                    jobId: "preview-job"
                )
                
                // Trigger load
                viewModel.setTrackId(trackId.uuidString)
            }
        }
    }
    
    return PreviewWrapper()
}
