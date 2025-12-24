import SwiftUI

// MARK: - Transcript Viewer Sheet

/// Sheet for viewing and searching transcripts
struct TranscriptViewerSheet: View {
    let trackId: String
    let trackName: String
    private let showTrackSummary: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var baiduAuth: BaiduAuthViewModel
    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: TranscriptViewModel
    @StateObject private var trackSummaryViewModel = TrackSummaryViewModel()
    @State private var selectedSegment: TranscriptSegment?
    @State private var playbackAlertMessage: String?
    @State private var scrollTargetSegmentID: String?
    @State private var scrollTargetShouldAnimate = true
    @State private var lastAutoScrolledSegmentID: String?
    @State private var hasQueuedInitialFocus = false
    @State private var isAutoFocusEnabled = true
    @State private var showJumpToCurrentButton = false

    init(trackId: String, trackName: String, showTrackSummary: Bool = false) {
        self.trackId = trackId
        self.trackName = trackName
        self.showTrackSummary = showTrackSummary
        _viewModel = StateObject(wrappedValue: TranscriptViewModel(trackId: trackId))
    }

    var body: some View {
        mainView
    }

    @ViewBuilder
    private var mainView: some View {
        NavigationStack {
            scrollableContent
                .navigationTitle(trackName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems() }
                .background(themeManager.colors.isFestive ? themeManager.colors.background : Color(uiColor: .systemBackground))
        }
        .task {
            await viewModel.loadTranscript()
            await viewModel.refreshTranslations()
            handleRepairJobUpdates()
            if showTrackSummary {
                trackSummaryViewModel.setTrackId(trackId)
                await refreshSummaryTranslations()
                handleTrackSummaryJobUpdates()
            }

            queueInitialAutoFocus()
            refreshJumpButtonVisibility()
        }
        .onChange(of: segmentIDs) {
            lastAutoScrolledSegmentID = nil
            focusOnCurrentPlayback(currentTime: audioPlayer.currentTime, animated: false)
            refreshJumpButtonVisibility()
        }
        .onChange(of: audioPlayer.currentTrack?.id) {
            lastAutoScrolledSegmentID = nil
            focusOnCurrentPlayback(currentTime: audioPlayer.currentTime, animated: false)
            refreshJumpButtonVisibility()
        }
        .onChange(of: viewModel.isLoading) { isLoading in
            if !isLoading {
                queueInitialAutoFocus()
                refreshJumpButtonVisibility()
            }
        }
        .background(PlaybackAutoFollowObserver { currentTime in
            focusOnCurrentPlayback(currentTime: currentTime, animated: true)
        })
        .onChange(of: viewModel.searchText) { newValue in
            if newValue.isEmpty {
                lastAutoScrolledSegmentID = nil
                focusOnCurrentPlayback(currentTime: audioPlayer.currentTime, animated: false)
            }
        }
        .alert(
            NSLocalizedString("error_title", comment: "Generic error title"),
            isPresented: Binding(
                get: { playbackAlertMessage != nil },
                set: { newValue in
                    if !newValue {
                        playbackAlertMessage = nil
                    }
                }
            )
        ) {
            Button("ok_button", role: .cancel) {
                playbackAlertMessage = nil
            }
        } message: {
            Text(playbackAlertMessage ?? "")
        }
        .onChange(of: aiGenerationManager.recentJobs) {
            handleRepairJobUpdates()
            handleTrackSummaryJobUpdates()
        }
        .onChange(of: aiGenerationManager.activeJobs) {
            handleRepairJobUpdates()
            handleTrackSummaryJobUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptDidFinalize)) { notification in
            guard let completedTrackId = notification.userInfo?["trackId"] as? String else { return }
            handleTrackSummaryTranscriptFinalized(trackId: completedTrackId)
        }
    }

    // MARK: - Private Methods

    @ViewBuilder
    private func repairStatusSection() -> some View {
        Group {
            if viewModel.isRepairing {
                repairBanner(
                    icon: "wand.and.stars",
                    text: NSLocalizedString("ai_repair_in_progress", comment: "AI repair in progress"),
                    tint: .accentColor
                )
            } else if let error = viewModel.repairErrorMessage {
                repairBanner(
                    icon: "exclamationmark.triangle.fill",
                    text: error,
                    tint: .red
                ) {
                    viewModel.repairErrorMessage = nil
                }
            } else if let summary = repairSummaryText {
                repairBanner(
                    icon: "checkmark.seal.fill",
                    text: summary,
                    tint: .green
                ) {
                    viewModel.lastRepairResults = []
                }
            }
        }
    }

    private var repairSummaryText: String? {
        let count = viewModel.lastRepairResults.count
        guard count > 0 else { return nil }
        if count == 1 {
            return NSLocalizedString("ai_repair_applied_single", comment: "Single segment repaired")
        }
        let format = NSLocalizedString("ai_repair_applied_multiple", comment: "Multiple segments repaired")
        return String(format: format, count)
    }

    @ViewBuilder
    private func repairBanner(icon: String, text: String, tint: Color, dismissAction: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

        @ViewBuilder
        private func transcriptContent() -> some View {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        Task { await viewModel.loadTranscript() }
                    }) {
                        Text("retry_button")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.segments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.gray)

                    Text("no_transcript_found")
                        .font(.headline)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchText.isEmpty {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if displayedSegments.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)

                            Text("no_transcript_found")
                                .font(.headline)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(displayedSegments, id: \.index) { item in
                            let segment = item.segment
                            TranscriptSegmentRowView(
                                segment: segment,
                                translation: viewModel.translation(for: segment),
                                isSelected: selectedSegment?.id == segment.id,
                                onTap: {
                                    selectedSegment = segment
                                    jumpToSegment(segment)
                                },
                                themeManager: themeManager
                            )
                            .id(segment.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                if viewModel.searchResults.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.gray)

                        Text("no_search_results")
                            .font(.headline)

                        Text("transcript_search_no_matches")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        SearchSummaryView(
                            query: viewModel.searchText,
                            totalMatches: viewModel.searchResults.count
                        )
                        .padding(.horizontal, 8)

                        ForEach(viewModel.searchResults) { result in
                            SearchResultRow(
                                result: result,
                                highlightedText: viewModel.highlightedSegmentText(result.segment),
                                isSelected: selectedSegment?.id == result.segment.id,
                                onTap: {
                                    selectedSegment = result.segment
                                    jumpToSegment(result.segment)
                                }
                            )
                            .id(result.segment.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }

    private var headerSection: some View {
        VStack(spacing: 8) {
            SearchBar(
                text: $viewModel.searchText,
                placeholder: "search_in_transcript"
            )

            repairStatusSection()
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                // Corrections page link
                if viewModel.transcript != nil {
                    NavigationLink {
                        TranscriptCorrectionsView(trackId: trackId, trackName: trackName)
                    } label: {
                        Image(systemName: "text.badge.checkmark")
                    }
                }

                Button("close_button") {
                    dismiss()
                }
            }
        }

        if !viewModel.searchText.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: viewModel.clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scrollableContent: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        if showTrackSummary, let context = resolveTrackContext() {
                            TrackSummaryCard(
                                track: context.track,
                                isTranscriptAvailable: viewModel.transcript != nil,
                                viewModel: trackSummaryViewModel,
                                seekAndPlayAction: { time in seekAndPlay(to: time) },
                                onRequestTranscription: {
                                    Task { await viewModel.loadTranscript() }
                                },
                                onRequestTranslations: {
                                    Task { await triggerTranslationGeneration() }
                                }
                            )
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        }

                        headerSection
                            .padding(.horizontal)
                            .padding(.bottom, 8)

                        transcriptContent()
                            .padding(.horizontal)
                            .padding(.bottom, 16)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if isAutoFocusEnabled {
                                isAutoFocusEnabled = false
                                showJumpToCurrentButton = true
                            }
                        }
                )
                .onChange(of: scrollTargetSegmentID) { target in
                    guard let target else { return }
                    let scrollAction = {
                        proxy.scrollTo(target, anchor: .center)
                    }

                    if scrollTargetShouldAnimate {
                        withAnimation(.easeInOut) {
                            scrollAction()
                        }
                    } else {
                        scrollAction()
                    }
                }

                // Floating button to jump to current segment and re-enable auto-focus
                if showJumpToCurrentButton && isViewingCurrentTrack && !viewModel.segments.isEmpty {
                    Button {
                        isAutoFocusEnabled = true
                        showJumpToCurrentButton = false
                        lastAutoScrolledSegmentID = nil
                        focusOnCurrentPlayback(currentTime: audioPlayer.currentTime, animated: true)
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private func jumpToSegment(_ segment: TranscriptSegment) {
        guard let context = resolveTrackContext() else {
            playbackAlertMessage = NSLocalizedString(
                "transcript_track_not_found_message",
                comment: "Shown when transcript track cannot be located for playback"
            )
            return
        }

        let position = viewModel.getPlaybackPosition(for: segment)
        lastAutoScrolledSegmentID = segment.id

        if audioPlayer.currentTrack?.id != context.track.id || audioPlayer.activeCollection?.id != context.collection.id {
            audioPlayer.play(track: context.track, in: context.collection, token: baiduAuth.token)
        }

        audioPlayer.seek(to: position)
    }

    private func seekAndPlay(to time: TimeInterval) {
        guard let context = resolveTrackContext() else {
            playbackAlertMessage = NSLocalizedString(
                "transcript_track_not_found_message",
                comment: "Shown when transcript track cannot be located for playback"
            )
            return
        }

        if audioPlayer.currentTrack?.id != context.track.id || audioPlayer.activeCollection?.id != context.collection.id {
            audioPlayer.play(track: context.track, in: context.collection, token: baiduAuth.token)
        }

        audioPlayer.seek(to: time)
    }

    private func resolveTrackContext() -> (track: AudiobookTrack, collection: AudiobookCollection)? {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return (track, collection)
            }
        }
        return nil
    }

    private func focusOnCurrentPlayback(currentTime: Double, animated: Bool) {
        guard shouldAutoFollowPlayback,
              let segment = viewModel.segmentClosest(to: currentTime) else {
            return
        }

        selectedSegment = segment

        if lastAutoScrolledSegmentID == segment.id {
            return
        }

        lastAutoScrolledSegmentID = segment.id
        setScrollTarget(segment.id, animated: animated)
    }

    private func setScrollTarget(_ id: String, animated: Bool) {
        scrollTargetShouldAnimate = animated
        // Reset the target before scheduling the actual scroll so ScrollViewReader
        // sees a state change even if we're requesting the same segment ID twice.
        scrollTargetSegmentID = nil

        let targetID = id
        DispatchQueue.main.async {
            self.scrollTargetSegmentID = targetID
        }
    }

    private var shouldAutoFollowPlayback: Bool {
        guard isAutoFocusEnabled else { return false }
        guard isViewingCurrentTrack else { return false }
        guard viewModel.searchText.isEmpty else { return false }
        return !viewModel.segments.isEmpty
    }

    private var isViewingCurrentTrack: Bool {
        audioPlayer.currentTrack?.id.uuidString == trackId
    }

    private var segmentIDs: [String] {
        viewModel.segments.map { $0.id }
    }

    private var displayedSegments: [(index: Int, segment: TranscriptSegment)] {
        let indices = Array(viewModel.segments.indices)
        return indices.map { ($0, viewModel.segments[$0]) }
    }

    private func queueInitialAutoFocus() {
        guard !hasQueuedInitialFocus else { return }
        guard shouldAutoFollowPlayback else { return }
        guard !viewModel.segments.isEmpty else { return }

        hasQueuedInitialFocus = true

        DispatchQueue.main.async {
            focusOnCurrentPlayback(currentTime: audioPlayer.currentTime, animated: false)
        }
    }

    private func refreshJumpButtonVisibility() {
        showJumpToCurrentButton = isViewingCurrentTrack && !viewModel.segments.isEmpty
    }
}

// MARK: - Segment Row Component

struct TranscriptSegmentRowView: View {
    let segment: TranscriptSegment
    let translation: TrackSummaryTranslation?
    let isSelected: Bool
    let onTap: () -> Void
    var themeManager: ThemeManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(segment.formattedStartTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let confidence = segment.confidence {
                    Text(
                        String(
                            format: NSLocalizedString("transcript_confidence_format", comment: "Transcript confidence percentage"),
                            locale: .current,
                            confidence * 100
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(height: 16)

            Text(segment.text)
                .font(.body)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            if let translation {
                Text(translation.translation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected ?
                        (themeManager?.colors.isFestive == true ? (themeManager?.colors.festiveGold.opacity(0.2) ?? Color.accentColor.opacity(0.12)) : Color.accentColor.opacity(0.12))
                        : (themeManager?.colors.isFestive == true ? (themeManager?.colors.background ?? Color(.systemBackground)) : Color(.systemBackground))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isSelected ?
                        (themeManager?.colors.isFestive == true ? (themeManager?.colors.festiveGold ?? Color.accentColor) : Color.accentColor)
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Search Result Row Component

struct SearchResultRow: View {
    let result: TranscriptSearchResult
    let highlightedText: NSAttributedString
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Text(result.segment.formattedStartTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(matchCountText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundStyle(Color.accentColor)
            }

            HighlightedTranscriptText(attributedString: highlightedText)
                .font(.body)
                .lineSpacing(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var matchCountText: String {
        if result.matchCount == 1 {
            return NSLocalizedString("transcript_search_result_single", comment: "Single transcript search match")
        } else {
            return String(
                format: NSLocalizedString("transcript_search_result_plural", comment: "Multiple transcript search matches"),
                locale: .current,
                result.matchCount
            )
        }
    }
}

private extension TranscriptViewerSheet {
    var activeRepairJobForTranscript: AIGenerationJob? {
        guard let transcriptId = viewModel.transcript?.id else { return nil }
        return aiGenerationManager.activeJobs.first { $0.type == .transcriptRepair && $0.transcriptId == transcriptId }
    }

    func handleRepairJobUpdates() {
        guard viewModel.transcript != nil else { return }
        viewModel.isRepairing = activeRepairJobForTranscript != nil
        guard let transcriptId = viewModel.transcript?.id else { return }
        guard let job = aiGenerationManager.recentJobs.first(where: { $0.type == .transcriptRepair && $0.transcriptId == transcriptId }) else {
            return
        }

        switch job.status {
        case .completed:
            if let metadata = job.decodedMetadata(), let results = metadata.repairResults {
                viewModel.lastRepairResults = results
            }
            Task { await viewModel.loadTranscript() }
            viewModel.repairErrorMessage = nil
        case .failed:
            viewModel.repairErrorMessage = job.errorMessage
        default:
            break
        }
    }

    func handleTrackSummaryJobUpdates() {
        guard showTrackSummary else { return }
        trackSummaryViewModel.handleJobUpdates(
            activeJobs: aiGenerationManager.activeJobs,
            recentJobs: aiGenerationManager.recentJobs
        )

        Task { await refreshSummaryTranslations() }
    }

    func handleTrackSummaryTranscriptFinalized(trackId: String) {
        guard showTrackSummary else { return }
        guard trackId == self.trackId else { return }
        trackSummaryViewModel.handleTranscriptFinalized(trackId: trackId)
        Task { await refreshSummaryTranslations() }
    }

    private func refreshSummaryTranslations() async {
        guard showTrackSummary else { return }
        await viewModel.refreshTranslations()
    }

    private func triggerTranslationGeneration() async {
        guard viewModel.transcript != nil else {
            await MainActor.run {
                playbackAlertMessage = NSLocalizedString(
                    "track_summary_requires_transcript",
                    comment: "Translation generation requires transcript"
                )
            }
            return
        }

        do {
            let modelId = aiGateway.selectedModelID
            try await trackSummaryViewModel.startGeneration(
                using: aiGenerationManager,
                modelId: modelId,
                includeKeywords: true,
                requestTranslations: true
            )
        } catch {
            await MainActor.run {
                playbackAlertMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Search Summary

private struct SearchSummaryView: View {
    let query: String
    let totalMatches: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                String(
                    format: NSLocalizedString("transcript_search_results", comment: "Transcript search header"),
                    locale: .current,
                    query
                )
            )
            .font(.headline)

            Text(summaryCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCountText: String {
        if totalMatches == 1 {
            return NSLocalizedString(
                "transcript_search_result_single",
                comment: "Displayed when transcript search has exactly one match"
            )
        } else {
            return String(
                format: NSLocalizedString(
                    "transcript_search_result_plural",
                    comment: "Displayed when transcript search has multiple matches"
                ),
                locale: .current,
                totalMatches
            )
        }
    }
}

// MARK: - Search Bar Component

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString(placeholder, comment: ""), text: $text)
                .textFieldStyle(.roundedBorder)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - Attributed Text for Highlighting

struct HighlightedTranscriptText: View {
    let attributedString: NSAttributedString

    var body: some View {
        Group {
            if let converted = try? AttributedString(attributedString) {
                Text(converted)
            } else {
                Text(attributedString.string)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaybackAutoFollowObserver: View {
    @EnvironmentObject private var playbackClock: PlaybackClock
    let onTick: (Double) -> Void

    var body: some View {
        Color.clear
            .onChange(of: playbackClock.currentTime) { newValue in
                onTick(newValue)
            }
    }
}

// MARK: - Preview

#Preview {
    Text("TranscriptViewerSheet preview disabled for now")
}
