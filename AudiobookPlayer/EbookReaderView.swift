import SwiftUI

struct EbookReaderView: View {
    let collection: AudiobookCollection
    
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    
    @State private var currentTrack: AudiobookTrack
    @State private var textContent: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    @AppStorage("ebook_reader_font_scale") private var fontScale: Double = 1.0
    @AppStorage("ebook_reader_line_height") private var lineHeight: Double = 1.4
    @AppStorage("ebook_reader_use_serif") private var useSerifFont = true
    @AppStorage("ebook_reader_theme") private var themeRawValue: String = EbookReaderTheme.paper.rawValue
    
    @State private var showSettingsSheet = false
    
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 1
    @State private var viewportHeight: CGFloat = 1
    @State private var scrollProgress: Double = 0
    
    private let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
    
    init(track: AudiobookTrack, collection: AudiobookCollection) {
        self.collection = collection
        _currentTrack = State(initialValue: track)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                selectedTheme.backgroundColor
                    .ignoresSafeArea()
                
                ScrollViewReader { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            headerView
                            contentBody
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                    }
                    .id(currentTrack.id)
                    .coordinateSpace(name: "ebookScroll")
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: -proxy.frame(in: .named("ebookScroll")).origin.y)
                        }
                    )
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(ContentHeightPreferenceKey.self) { value in
                        contentHeight = max(value, 1)
                        updateScrollProgress()
                    }
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        scrollOffset = max(0, value)
                        updateScrollProgress()
                    }
                }
            }
            .onAppear {
                viewportHeight = geometry.size.height
                updateScrollProgress()
            }
            .onChange(of: geometry.size.height) { newValue in
                viewportHeight = newValue
                updateScrollProgress()
            }
        }
        .navigationTitle(currentTrack.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: currentTrack.id) {
            await loadContent(for: currentTrack)
        }
        .safeAreaInset(edge: .bottom) {
            ReaderBottomBar(
                chapterText: chapterProgressText,
                progressText: percentFormatter.string(from: NSNumber(value: scrollProgress)) ?? "0%",
                progressValue: scrollProgress,
                theme: selectedTheme,
                canGoPrevious: previousTrack != nil,
                canGoNext: nextTrack != nil,
                onPrevious: navigateToPreviousTrack,
                onNext: navigateToNextTrack
            )
        }
        .sheet(isPresented: $showSettingsSheet) {
            ReaderSettingsSheet(
                fontScale: $fontScale,
                lineHeight: $lineHeight,
                useSerifFont: $useSerifFont,
                theme: themeBinding
            )
        }
    }
    
    private var selectedTheme: EbookReaderTheme {
        EbookReaderTheme(rawValue: themeRawValue) ?? .paper
    }
    
    private var themeBinding: Binding<EbookReaderTheme> {
        Binding(
            get: { EbookReaderTheme(rawValue: themeRawValue) ?? .paper },
            set: { themeRawValue = $0.rawValue }
        )
    }
    
    private var fontSize: CGFloat {
        let clampedScale = min(max(fontScale, 0.85), 1.5)
        return CGFloat(18 * clampedScale)
    }
    
    private var lineSpacingValue: CGFloat {
        CGFloat(fontSize * max(lineHeight - 1.0, 0.2))
    }
    
    private var textTracks: [AudiobookTrack] {
        var tracks = collection.tracks.filter { $0.isTextTrack }
        if !tracks.contains(where: { $0.id == currentTrack.id }) {
            tracks.append(currentTrack)
        }
        return tracks.sorted { lhs, rhs in
            if lhs.trackNumber != rhs.trackNumber {
                return lhs.trackNumber < rhs.trackNumber
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
    
    private var currentTextTrackIndex: Int? {
        textTracks.firstIndex { $0.id == currentTrack.id }
    }
    
    private var previousTrack: AudiobookTrack? {
        guard let index = currentTextTrackIndex, index > 0 else { return nil }
        return textTracks[index - 1]
    }
    
    private var nextTrack: AudiobookTrack? {
        guard let index = currentTextTrackIndex, index + 1 < textTracks.count else { return nil }
        return textTracks[index + 1]
    }
    
    private var chapterProgressText: String? {
        guard let index = currentTextTrackIndex else { return nil }
        let template = NSLocalizedString("reader_chapter_progress_format", value: "Chapter %d of %d", comment: "Chapter progress format")
        return String(format: template, index + 1, textTracks.count)
    }
    
    private var characterCountText: String? {
        guard let count = currentCharacterCount else { return nil }
        let formatted = integerFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let template = NSLocalizedString("reader_character_count_format", value: "%@ characters", comment: "Character count format")
        return String(format: template, formatted)
    }
    
    private var currentCharacterCount: Int? {
        if let stored = currentTrack.characterCount {
            return stored
        }
        return textContent.isEmpty ? nil : textContent.count
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if textTracks.count > 1 {
                chapterMenu
            }
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel(Text(NSLocalizedString("reader_settings_accessibility", comment: "Reader settings accessibility label")))
            
            Button {
                handleAudioAction()
            } label: {
                Image(systemName: hasGeneratedAudio ? "play.circle.fill" : "waveform.badge.plus")
            }
            .accessibilityLabel(
                Text(
                    hasGeneratedAudio
                    ? NSLocalizedString("reader_play_audio_accessibility", comment: "Play generated audio accessibility")
                    : NSLocalizedString("reader_generate_audio_accessibility", comment: "Generate audio accessibility")
                )
            )
        }
    }
    
    private var chapterMenu: some View {
        Menu {
            ForEach(textTracks) { track in
                Button {
                    switchToTrack(track)
                } label: {
                    Label(track.displayName, systemImage: track.id == currentTrack.id ? "book.fill" : "book")
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel(Text(NSLocalizedString("reader_table_of_contents_accessibility", comment: "Chapters menu accessibility")))
    }
    
    @ViewBuilder
    private var contentBody: some View {
        if isLoading {
            loadingView
        } else if let errorMessage {
            errorView(message: errorMessage)
        } else if textContent.isEmpty {
            emptyStateView
        } else {
            Text(textContent)
                .font(.system(size: fontSize, weight: .regular, design: useSerifFont ? .serif : .default))
                .foregroundStyle(selectedTheme.textColor)
                .lineSpacing(lineSpacingValue)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chapterProgressText {
                Text(chapterProgressText)
                    .font(.footnote)
                    .foregroundStyle(selectedTheme.mutedTextColor)
            }
            if let characterCountText {
                Text(characterCountText)
                    .font(.footnote)
                    .foregroundStyle(selectedTheme.mutedTextColor)
            }
        }
    }
    
    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(selectedTheme.textColor)
            Button(NSLocalizedString("reader_retry_button", value: "Retry", comment: "Reader retry button")) {
                Task { await loadContent(for: currentTrack) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.title)
                .foregroundStyle(selectedTheme.mutedTextColor)
            Text(NSLocalizedString("reader_no_text_message", value: "No text was found for this chapter.", comment: "Reader empty state"))
                .multilineTextAlignment(.center)
                .foregroundStyle(selectedTheme.mutedTextColor)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var hasGeneratedAudio: Bool {
        audioPlayer.hasGeneratedAudio(for: currentTrack)
    }
    
    private func handleAudioAction() {
        if hasGeneratedAudio {
            audioPlayer.play(track: currentTrack, in: collection, token: nil)
        } else {
            audioPlayer.generateAudio(for: currentTrack, in: collection, autoPlay: true)
        }
    }
    
    private func navigateToPreviousTrack() {
        guard let previousTrack else { return }
        switchToTrack(previousTrack)
    }
    
    private func navigateToNextTrack() {
        guard let nextTrack else { return }
        switchToTrack(nextTrack)
    }
    
    private func switchToTrack(_ track: AudiobookTrack) {
        guard track.id != currentTrack.id else { return }
        currentTrack = track
        textContent = ""
        errorMessage = nil
        isLoading = true
        resetScrollMetrics()
    }
    
    private func resetScrollMetrics() {
        scrollOffset = 0
        contentHeight = 1
        scrollProgress = 0
    }
    
    private func updateScrollProgress() {
        guard contentHeight > viewportHeight else {
            scrollProgress = textContent.isEmpty ? 0 : 1
            return
        }
        let scrollableHeight = max(contentHeight - viewportHeight, 1)
        let progress = scrollOffset / scrollableHeight
        scrollProgress = max(0, min(progress.isFinite ? progress : 0, 1))
    }
    
    private func loadContent(for track: AudiobookTrack) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            textContent = ""
            resetScrollMetrics()
        }
        
        var loadedText: String?
        var loadError: String?
        
        switch track.location {
        case .text(let content):
            loadedText = content
        case .cachedText(let filename):
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)
            do {
                loadedText = try String(contentsOf: url)
            } catch {
                loadError = String(
                    format: NSLocalizedString("reader_cached_file_error", value: "Failed to load text content (%@).", comment: "Cached file error"),
                    error.localizedDescription
                )
            }
        default:
            loadError = NSLocalizedString("reader_missing_text_error", value: "This track does not contain text content.", comment: "Missing text error")
        }
        
        await MainActor.run {
            if let loadError {
                errorMessage = loadError
                textContent = ""
            } else if let loadedText, !loadedText.isEmpty {
                textContent = loadedText
            } else {
                errorMessage = NSLocalizedString("reader_error_generic", value: "Failed to load text content.", comment: "Generic reader error")
            }
            isLoading = false
            updateScrollProgress()
        }
    }
}

private enum EbookReaderTheme: String, CaseIterable, Identifiable {
    case paper
    case sepia
    case night
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .paper:
            return NSLocalizedString("reader_theme_paper", value: "Paper", comment: "Reader theme paper")
        case .sepia:
            return NSLocalizedString("reader_theme_sepia", value: "Sepia", comment: "Reader theme sepia")
        case .night:
            return NSLocalizedString("reader_theme_night", value: "Night", comment: "Reader theme night")
        }
    }
    
    var backgroundColor: Color {
        switch self {
        case .paper:
            return Color(hexString: "#FFFCF5")
        case .sepia:
            return Color(hexString: "#F3E3D0")
        case .night:
            return Color(hexString: "#050609")
        }
    }
    
    var textColor: Color {
        switch self {
        case .paper:
            return Color(hexString: "#2F2415")
        case .sepia:
            return Color(hexString: "#2B2012")
        case .night:
            return Color(hexString: "#EEF2FF")
        }
    }
    
    var mutedTextColor: Color {
        textColor.opacity(0.7)
    }
    
    var accentColor: Color {
        switch self {
        case .paper:
            return Color(hexString: "#C47A3D")
        case .sepia:
            return Color(hexString: "#B4692D")
        case .night:
            return Color(hexString: "#5B8DEF")
        }
    }
    
    var bottomBarBackground: Color {
        switch self {
        case .paper:
            return Color.white.opacity(0.9)
        case .sepia:
            return Color(hexString: "#F9EFE1").opacity(0.95)
        case .night:
            return Color.black.opacity(0.7)
        }
    }
}

private struct ReaderBottomBar: View {
    let chapterText: String?
    let progressText: String
    let progressValue: Double
    let theme: EbookReaderTheme
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if let chapterText {
                    Text(chapterText)
                        .font(.caption)
                        .foregroundStyle(theme.mutedTextColor)
                }
                Spacer()
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedTextColor)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: NSLocalizedString("reader_progress_accessibility", value: "%@ read", comment: "Reader progress accessibility"),
                                progressText
                            )
                        )
                    )
            }
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(theme.accentColor)
            HStack {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoPrevious)
                .accessibilityLabel(Text(NSLocalizedString("reader_previous_chapter_accessibility", comment: "Previous chapter accessibility")))
                
                Spacer()
                
                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoNext)
                .accessibilityLabel(Text(NSLocalizedString("reader_next_chapter_accessibility", comment: "Next chapter accessibility")))
            }
            .font(.title3)
            .foregroundStyle(theme.textColor)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.bottomBarBackground)
    }
}

private struct ReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var fontScale: Double
    @Binding var lineHeight: Double
    @Binding var useSerifFont: Bool
    @Binding var theme: EbookReaderTheme
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("reader_font_size_label", value: "Font Size", comment: "Reader font size label"))) {
                    Slider(value: $fontScale, in: 0.85...1.5, step: 0.05) {
                        Text(NSLocalizedString("reader_font_size_label", comment: "Reader font size label"))
                    } minimumValueLabel: {
                        Text("A").font(.caption2)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    Text(String(format: NSLocalizedString("reader_font_size_value", value: "%d %%", comment: "Reader font size value"), Int(fontScale * 100)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section(header: Text(NSLocalizedString("reader_line_height_label", value: "Line Height", comment: "Reader line height label"))) {
                    Slider(value: $lineHeight, in: 1.2...2.0, step: 0.05)
                    Text(String(format: NSLocalizedString("reader_line_height_value", value: "%.2f×", comment: "Reader line height value"), lineHeight))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    Toggle(NSLocalizedString("reader_font_style_label", value: "Use serif body text", comment: "Reader font style label"), isOn: $useSerifFont)
                }
                
                Section(header: Text(NSLocalizedString("reader_theme_label", value: "Theme", comment: "Reader theme label"))) {
                    Picker(NSLocalizedString("reader_theme_label", comment: "Reader theme label"), selection: $theme) {
                        ForEach(EbookReaderTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(NSLocalizedString("reader_settings_title", value: "Reading Settings", comment: "Reader settings title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("done_button", comment: "Done button")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
