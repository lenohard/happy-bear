import SwiftUI

// MARK: - Transcript Viewer Sheet

/// Sheet for viewing and searching transcripts
struct TranscriptViewerSheet: View {
    let trackId: String
    let trackName: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var baiduAuth: BaiduAuthViewModel
    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @StateObject private var viewModel: TranscriptViewModel
    @State private var selectedSegment: TranscriptSegment?
    @State private var playbackAlertMessage: String?
    @State private var scrollTargetSegmentID: String?
    @State private var scrollTargetShouldAnimate = true
    @State private var lastAutoScrolledSegmentID: String?
    @State private var isRepairMode = false
    @State private var repairSelection = IndexSet()
    @State private var autoSelectThresholdPercent: Double = 95
    @State private var showSelectedOnly = false
    @State private var hideRepairedSegments = false
    @State private var repairControlsExpanded = true
    @State private var lastObservedRepairJobId: String?

    init(trackId: String, trackName: String) {
        self.trackId = trackId
        self.trackName = trackName
        _viewModel = StateObject(wrappedValue: TranscriptViewModel(trackId: trackId))
    }

    var body: some View {
        mainView
    }

    @ViewBuilder
    private var mainView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerSection
                transcriptScroll
            }
            .navigationTitle(trackName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems() }
        }
        .task {
            await viewModel.loadTranscript()
            handleRepairJobUpdates()
        }
        .onChange(of: segmentIDs) { _ in
            lastAutoScrolledSegmentID = nil
            focusOnCurrentPlayback(animated: false)
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            lastAutoScrolledSegmentID = nil
            focusOnCurrentPlayback(animated: false)
        }
        .onChange(of: audioPlayer.currentTime) { _ in
            focusOnCurrentPlayback(animated: true)
        }
        .onChange(of: viewModel.searchText) { newValue in
            if newValue.isEmpty {
                lastAutoScrolledSegmentID = nil
                focusOnCurrentPlayback(animated: false)
            } else if isRepairMode {
                exitRepairMode()
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
        .onChange(of: hideRepairedSegments) { newValue in
            if newValue {
                pruneSelectionForHiddenSegments()
            }
        }
        .onChange(of: viewModel.segments.count) { _ in
            pruneSelectionForHiddenSegments()
        }
        .onChange(of: aiGenerationManager.recentJobs) { _ in
            handleRepairJobUpdates()
        }
        .onChange(of: aiGenerationManager.activeJobs) { _ in
            handleRepairJobUpdates()
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if displayedSegments.isEmpty && showSelectedOnly {
                            VStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("No segments match the current selection filter.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        } else {
                            ForEach(displayedSegments, id: \.index) { item in
                                let index = item.index
                                let segment = item.segment
                                TranscriptSegmentRowView(
                                    segment: segment,
                                    isSelected: selectedSegment?.id == segment.id,
                                    isChecked: repairSelection.contains(index),
                                    showCheckbox: isRepairMode,
                                    isRepaired: segment.lastRepairModel != nil || segment.lastRepairAt != nil,
                                    onTap: {
                                        if isRepairMode {
                                            toggleRepairSelection(index)
                                        } else {
                                            selectedSegment = segment
                                            jumpToSegment(segment)
                                        }
                                    },
                                    onCheck: {
                                        toggleRepairSelection(index)
                                    }
                                )
                                .id(segment.id)
                            }
                        }
                    }
                    .padding()
                }
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            SearchSummaryView(
                                query: viewModel.searchText,
                                totalMatches: viewModel.searchResults.count
                            )
                            .padding(.horizontal)

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
                        .padding()
                    }
                }
            }
        }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SearchBar(
                    text: $viewModel.searchText,
                    placeholder: "search_in_transcript"
                )

                if isRepairMode {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            repairControlsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: repairControlsExpanded ? "chevron.up.circle" : "slider.horizontal.3")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(NSLocalizedString("repair_controls_toggle", comment: "Toggle repair controls")))
                }
            }

            repairStatusSection()

            if isRepairMode && repairControlsExpanded {
                repairModeControls()
            }
        }
        .padding()
    }

    @ToolbarContentBuilder
    private func toolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("close_button") {
                dismiss()
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

        repairToolbarItems()
    }

    @ViewBuilder
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            transcriptContent()
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

        // Dismiss after a short delay to show selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }

    private func resolveTrackContext() -> (track: AudiobookTrack, collection: AudiobookCollection)? {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return (track, collection)
            }
        }
        return nil
    }

    private func focusOnCurrentPlayback(animated: Bool) {
        guard shouldAutoFollowPlayback,
              let segment = viewModel.segmentClosest(to: audioPlayer.currentTime) else {
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
        let filtered: [Int]
        if isRepairMode {
            var working = indices
            if hideRepairedSegments {
                working = working.filter { idx in
                    let segment = viewModel.segments[idx]
                    return segment.lastRepairModel == nil && segment.lastRepairAt == nil
                }
            }
            if showSelectedOnly {
                working = working.filter { repairSelection.contains($0) }
            }
            filtered = working
        } else {
            filtered = indices
        }
        return filtered.map { ($0, viewModel.segments[$0]) }
    }

    private func toggleRepairSelection(_ index: Int) {
        if repairSelection.contains(index) {
            repairSelection.remove(index)
            if repairSelection.isEmpty {
                showSelectedOnly = false
            }
        } else {
            repairSelection.insert(index)
        }
    }

    private func exitRepairMode() {
        isRepairMode = false
        repairSelection.removeAll()
        showSelectedOnly = false
        repairControlsExpanded = true
    }

    private func startRepairMode() {
        guard hasAIRepairAccess else {
            viewModel.repairErrorMessage = NSLocalizedString("ai_repair_missing_key", comment: "AI key missing")
            return
        }
        repairSelection.removeAll()
        showSelectedOnly = false
        viewModel.repairErrorMessage = nil
        viewModel.lastRepairResults = []
        isRepairMode = true
        repairControlsExpanded = true
    }

    private func runRepair() async {
        guard resolvedAIKey != nil else {
            viewModel.repairErrorMessage = NSLocalizedString("ai_repair_missing_key", comment: "")
            return
        }
        guard let transcript = viewModel.transcript else {
            viewModel.repairErrorMessage = "Transcript not loaded."
            return
        }

        let indexes = Array(repairSelection).sorted()
        guard !indexes.isEmpty else {
            viewModel.repairErrorMessage = "No valid segments selected for repair."
            return
        }

        guard let context = resolveTrackContext() else {
            viewModel.repairErrorMessage = "Track context unavailable."
            return
        }

        do {
            let job = try await aiGenerationManager.enqueueTranscriptRepairJob(
                transcriptId: transcript.id,
                trackId: context.track.id.uuidString,
                trackTitle: trackName,
                collectionTitle: context.collection.title,
                collectionDescription: context.collection.description,
                selectionIndexes: indexes,
                instructions: nil,
                modelId: aiGateway.selectedModelID
            )
            viewModel.lastRepairResults = []
            viewModel.repairErrorMessage = nil
            viewModel.isRepairing = true
            lastObservedRepairJobId = job.id
            exitRepairMode()
        } catch {
            viewModel.repairErrorMessage = error.localizedDescription
        }
    }

    private var hasAIRepairAccess: Bool {
        resolvedAIKey != nil
    }

    private var resolvedAIKey: String? {
        let value = aiGateway.storedKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @ViewBuilder
    private func repairModeControls() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle row
            HStack(alignment: .center, spacing: 10) {
                Toggle(NSLocalizedString("repair_toggle_selected_only", comment: "Toggle label"), isOn: $showSelectedOnly)
                    .disabled(repairSelection.isEmpty)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Toggle(NSLocalizedString("repair_toggle_hide_repaired", comment: "Toggle label"), isOn: $hideRepairedSegments)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Toggle(NSLocalizedString("repair_toggle_select_all", comment: "Toggle label"), isOn: selectAllBinding)
                    .disabled(viewModel.segments.isEmpty)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.footnote)
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Slider + action row
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-select low confidence segments")
                            .font(.subheadline)
                            .bold()
                        Text(thresholdSummaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        toggleLowConfidenceSelection()
                    } label: {
                        Label(
                            isThresholdSelectionActive ? "Unselect" : "Select",
                            systemImage: isThresholdSelectionActive ? "arrow.uturn.backward.circle" : "line.3.horizontal.decrease.circle"
                        )
                        .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lowConfidenceCandidateCount == 0)
                }

                HStack(spacing: 12) {
                    Slider(
                        value: $autoSelectThresholdPercent,
                        in: 50...100,
                        step: 1
                    ) {
                        Text("Confidence threshold")
                    }
                    Text("\(Int(autoSelectThresholdPercent))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Text(statsSummaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if repairSelection.count > 0 {
                Text("Currently selected: \(repairSelection.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

    private var lowConfidenceCandidateCount: Int {
        lowConfidenceIndexes.count
    }

    private var repairedSegmentsCount: Int {
        viewModel.segments.filter { $0.lastRepairModel != nil || $0.lastRepairAt != nil }.count
    }

    private var selectedCharacterCount: Int {
        repairSelection.reduce(0) { partialResult, index in
            guard index < viewModel.segments.count else { return partialResult }
            return partialResult + viewModel.segments[index].text.count
        }
    }

    private var areAllSegmentsSelected: Bool {
        !viewModel.segments.isEmpty && repairSelection.count == viewModel.segments.count
    }

    private var thresholdSummaryText: String {
        let format = NSLocalizedString("repair_threshold_summary", comment: "Threshold summary")
        return String(format: format, Int(autoSelectThresholdPercent), lowConfidenceCandidateCount)
    }

    private var totalCharacterCount: Int {
        viewModel.segments.reduce(0) { $0 + $1.text.count }
    }

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { areAllSegmentsSelected },
            set: { newValue in
                if newValue {
                    selectAllRepairableSegments()
                } else {
                    repairSelection.removeAll()
                    showSelectedOnly = false
                }
            }
        )
    }

    private var lowConfidenceIndexes: IndexSet {
        var indexes = IndexSet()
        let threshold = autoSelectThresholdPercent / 100
        for (index, segment) in viewModel.segments.enumerated() {
            guard let confidence = segment.confidence else { continue }
            if confidence < threshold {
                indexes.insert(index)
            }
        }
        return indexes
    }

    private var isThresholdSelectionActive: Bool {
        let indexes = lowConfidenceIndexes
        guard !indexes.isEmpty else { return false }
        return indexes.allSatisfy { repairSelection.contains($0) }
    }

    private func toggleLowConfidenceSelection() {
        let indexes = lowConfidenceIndexes
        guard !indexes.isEmpty else { return }
        if isThresholdSelectionActive {
            for index in indexes {
                repairSelection.remove(index)
            }
            if repairSelection.isEmpty {
                showSelectedOnly = false
            }
        } else {
            for index in indexes {
                repairSelection.insert(index)
            }
        }
    }

    private func selectAllRepairableSegments() {
        repairSelection = IndexSet(viewModel.segments.indices)
    }

    private func pruneSelectionForHiddenSegments() {
        let validUpperBound = viewModel.segments.count
        var filtered = IndexSet(repairSelection.filter { $0 < validUpperBound })

        if hideRepairedSegments {
            let allowed = Set(viewModel.segments.enumerated().compactMap { idx, segment in
                (segment.lastRepairModel == nil && segment.lastRepairAt == nil) ? idx : nil
            })
            filtered = IndexSet(filtered.filter { allowed.contains($0) })
        }

        repairSelection = filtered
        if repairSelection.isEmpty {
            showSelectedOnly = false
        }
    }

    private var statsSummaryText: String {
        let matches = formattedCount(lowConfidenceCandidateCount)
        let selected = formattedCount(repairSelection.count)
        let totalSegments = formattedCount(viewModel.segments.count)
        let repaired = formattedCount(repairedSegmentsCount)
        let selectedChars = formattedCount(selectedCharacterCount)
        let totalChars = formattedCount(totalCharacterCount)

        let format = NSLocalizedString("repair_stats_summary_format", comment: "Stats summary format")
        return String(format: format, matches, selected, totalSegments, repaired, selectedChars, totalChars)
    }

    private func formattedCount(_ count: Int) -> String {
        numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
}

// MARK: - Segment Row Component

struct TranscriptSegmentRowView: View {
    let segment: TranscriptSegment
    let isSelected: Bool
    let isChecked: Bool
    let showCheckbox: Bool
    let isRepaired: Bool
    let onTap: () -> Void
    let onCheck: () -> Void

    init(
        segment: TranscriptSegment,
        isSelected: Bool,
        isChecked: Bool = false,
        showCheckbox: Bool = false,
        isRepaired: Bool = false,
        onTap: @escaping () -> Void,
        onCheck: @escaping () -> Void = {}
    ) {
        self.segment = segment
        self.isSelected = isSelected
        self.isChecked = isChecked
        self.showCheckbox = showCheckbox
        self.isRepaired = isRepaired
        self.onTap = onTap
        self.onCheck = onCheck
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(segment.formattedStartTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(segment.formattedEndTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 58, alignment: .leading)
                .alignmentGuide(.top) { d in d[.top] }

                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.text)
                        .font(.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let confidence = segment.confidence {
                        HStack(spacing: 4) {
                            if isRepaired {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
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
                    }
                }
                .alignmentGuide(.top) { d in d[.top] }

                Spacer()

                if showCheckbox {
                    Button(action: onCheck) {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Repair Toolbar

private extension TranscriptViewerSheet {
    @ToolbarContentBuilder
    func repairToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if isRepairMode {
                    exitRepairMode()
                } else {
                    startRepairMode()
                }
            } label: {
                if isRepairMode {
                    Label(NSLocalizedString("ai_repair_cancel", comment: ""), systemImage: "chevron.left")
                } else {
                    Label(NSLocalizedString("ai_repair_toggle", comment: ""), systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading || viewModel.segments.isEmpty || (!isRepairMode && !hasAIRepairAccess))
        }

        if isRepairMode {
            ToolbarItem {
                Button {
                    Task { await runRepair() }
                } label: {
                    if viewModel.isRepairing {
                        ProgressView()
                    } else {
                        Label(
                            NSLocalizedString("ai_repair_apply", comment: "Apply repairs"),
                            systemImage: "checkmark.seal"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRepairing || repairSelection.isEmpty || !hasAIRepairAccess)
            }
        } else if !hasAIRepairAccess {
            ToolbarItem {
                Text(NSLocalizedString("ai_repair_missing_key_hint", comment: "Prompt to add AI key"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Search Result Row Component

struct SearchResultRow: View {
    let result: TranscriptSearchResult
    let highlightedText: NSAttributedString
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(result.segment.formattedStartTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(matchCountText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundStyle(Color.accentColor)
            }

            AttributedText(highlightedText)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            guard lastObservedRepairJobId != job.id else { return }
            lastObservedRepairJobId = job.id
            if let metadata = job.decodedMetadata(), let results = metadata.repairResults {
                viewModel.lastRepairResults = results
            }
            Task { await viewModel.loadTranscript() }
            viewModel.repairErrorMessage = nil
        case .failed:
            guard lastObservedRepairJobId != job.id else { return }
            lastObservedRepairJobId = job.id
            viewModel.repairErrorMessage = job.errorMessage
        default:
            break
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

struct AttributedText: UIViewRepresentable {
    let attributedString: NSAttributedString

    init(_ attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.attributedText = attributedString
    }
}

// MARK: - Preview

#Preview {
    Text("TranscriptViewerSheet preview disabled for now")
}
