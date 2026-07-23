import SwiftUI
import Combine
import GRDB
import UIKit

@MainActor
final class CollectionDetailViewModel: ObservableObject {
    let collectionID: UUID
    
    // MARK: - Dependencies
    weak var library: LibraryStore?
    weak var audioPlayer: AudioPlayerViewModel?
    weak var authViewModel: BaiduAuthViewModel?
    weak var transcriptionManager: TranscriptionManager?
    weak var aiGenerationManager: AIGenerationManager?

    // MARK: - UI State
    @Published var searchText = ""
    @Published var missingAuthAlert = false
    @Published var showTrackPicker = false
    @Published var trackToDelete: AudiobookTrack?
    @Published var showDeleteConfirmation = false
    @Published var trackToRename: AudiobookTrack?
    @Published var trackTitleDraft = ""
    @Published var showCollectionInfoSheet = false
    @Published var showBatchRename = false
    @Published var showArchivedTracks = false
    @Published var collectionTitleDraft = ""
    @Published var collectionDescriptionDraft = ""
    @Published var collectionIsMusicDraft = false
    @Published var collectionFolderPathDraft: String? = nil
    @Published var collectionAutoUpdateEnabledDraft = true
    @Published var trackForTranscription: AudiobookTrack?
    @Published var trackForViewing: AudiobookTrack?
    @Published var trackForReading: AudiobookTrack?
    @Published var trackForTTSProgress: AudiobookTrack?
    @Published var trackForDetails: AudiobookTrack?
    @Published var trackForChat: AudiobookTrack?
    @Published var transcriptStatusCache: [UUID: Bool] = [:]
    @Published var pendingAutoFocusTrackId: UUID?
    @Published var didAutoFocusTrack = false
    @Published var trackPendingTranscriptDeletion: AudiobookTrack?
    @Published var showTranscriptDeletionDialog = false
    @Published var transcriptDeletionError: String?
    @Published var showTranscriptDeletionError = false
    @Published var tracksWithSummaries: Set<UUID> = []
    @Published var showCoverFileImporter = false
    @Published var showCoverPhotosPicker = false
    @Published var isUpdatingCover = false
    @Published var coverUpdateError: String?
    @Published var showCoverUpdateError = false
    @Published var showEbookFileImporter = false
    @Published var ebookImportError: String?
    @Published var isSummaryVisible = true
    @Published var isLastTrackVisible = false
    @Published var refreshResult: String?
    @Published var showRefreshResult = false
    @Published var isRefreshingCollection = false
    @Published var candidateTracks: [AudiobookTrack] = []
    @Published var selectedCandidateIds: Set<UUID> = []
    @Published var showRefreshReview = false
    @Published var refreshReviewTitle = ""
    @Published var refreshReviewDescription = ""
    @Published var playbackStateSnapshot: [UUID: TrackPlaybackState] = [:]
    @Published var isDescriptionExpanded = false
    @Published var expandedChapters: Set<String> = []
    @Published var didInitChapterState = false
    
    @Published var sttTranscribingTrackIds: Set<UUID> = []
    @Published var ttsGeneratingTrackIds: Set<UUID> = []
    
    // MARK: - Data Loading State
    @Published var cachedOrderedTracks: [AudiobookTrack] = []
    @Published var cachedSortedTracks: [AudiobookTrack] = []
    @Published var loadedPages: [Int: [AudiobookTrack]] = [:]
    @Published var loadingPages: Set<Int> = []
    @Published var totalPages: Int = 0
    @Published var totalResults: Int = 0
    @Published var isListLoading: Bool = false

    // MARK: - Derived / Cached View State
    // Cached to avoid recomputing on every SwiftUI render pass.
    @Published var cachedHasChapters: Bool = false
    @Published var cachedChapterGroups: [ChapterGroup] = []
    /// Total file size of all tracks in the current filtered list (used in summary header).
    @Published var cachedTotalTracksSize: Int64 = 0
    
    // MARK: - Filter & Sort State
    @Published var selectedFilter: FilterOption = .all
    @Published var selectedCriterion: SortCriterion = .trackNumber
    @Published var selectedOrder: SortOrder = .ascending
    
    // MARK: - Internal State
    var summaryIndicatorTask: Task<Void, Never>?
    var filterTask: Task<Void, Never>?
    var sortTask: Task<Void, Never>?
    var searchDebounceTask: Task<Void, Never>?
    var transcriptStatusTask: Task<Void, Never>?
    
    let pagingThreshold = 1000
    let pageSize = 500
    
    // Snapshot of current filter/sort to detect changes during reload
    var currentQuery: String = ""
    var currentFilterKey: FilterOption = .all
    var currentSortCriterion: SortCriterion = .trackNumber
    var currentSortOrder: SortOrder = .ascending
    var pagingQueryToken: UUID = UUID()
    
    init(collectionID: UUID) {
        self.collectionID = collectionID
    }
    
    func setup(
        library: LibraryStore,
        audioPlayer: AudioPlayerViewModel,
        authViewModel: BaiduAuthViewModel,
        transcriptionManager: TranscriptionManager,
        aiGenerationManager: AIGenerationManager
    ) {
        self.library = library
        self.audioPlayer = audioPlayer
        self.authViewModel = authViewModel
        self.transcriptionManager = transcriptionManager
        self.aiGenerationManager = aiGenerationManager
    }
    
    // MARK: - Computed Properties
    
    var collection: AudiobookCollection? {
        library?.collections.first { $0.id == collectionID }
    }

    var isEbookCollection: Bool {
        if let collection, case .ebook = collection.source {
            return true
        }
        return false
    }

    var isRSSCollection: Bool {
        if let collection, case .rss = collection.source {
            return true
        }
        return false
    }

    var canRefreshCurrentCollection: Bool {
        guard let source = collection?.source else { return false }
        switch source {
        case .baiduNetdisk, .rss:
            return true
        case .ebook(_, let bookmark):
            return bookmark != nil
        default:
            return false
        }
    }

    var isPagedMode: Bool {
        let countHint = max(
            totalResults,
            collection?.trackCount ?? 0,
            collection?.tracks.count ?? 0
        )
        return countHint > pagingThreshold
    }

    var archivedTracks: [AudiobookTrack] {
        if isPagedMode {
            return pagedTracks.filter { $0.isArchived }
        } else {
            guard let collection else { return [] }
            return collection.tracks.filter { $0.isArchived }
        }
    }
    
    var sortedTracks: [AudiobookTrack] {
        if isPagedMode {
            return pagedTracks
        } else {
            if !cachedSortedTracks.isEmpty { return cachedSortedTracks }
            guard let collection else { return [] }
            return sortTracks(collection.tracks, by: selectedCriterion, order: selectedOrder)
        }
    }

    var pagedTracks: [AudiobookTrack] {
        // Combine loaded pages in order
        let keys = loadedPages.keys.sorted()
        return keys.flatMap { loadedPages[$0] ?? [] }
    }
    
    var filteredTracks: [AudiobookTrack] {
        cachedOrderedTracks
    }
    
    // MARK: - Chapter Grouping
    
    /// Struct representing a chapter group with its tracks
    struct ChapterGroup: Identifiable {
        let id: String  // chapter name or "ungrouped"
        let chapter: String?
        let tracks: [AudiobookTrack]
    }
    
    /// Returns true if any track has a chapter assigned.
    /// Read from the pre-computed cache — do NOT call filteredTracks inline here.
    var hasChapters: Bool { cachedHasChapters }
    
    /// Groups tracks by chapter, with ungrouped tracks (nil chapter) at the end.
    /// Read from the pre-computed cache — do NOT call filteredTracks inline here.
    var chapterGroups: [ChapterGroup] { cachedChapterGroups }

    /// Recomputes all derived view-state caches from the current `cachedOrderedTracks`.
    /// Must be called on @MainActor whenever `cachedOrderedTracks` is mutated.
    func recomputeDerivedViewState() {
        let tracks = cachedOrderedTracks

        // hasChapters
        let hasChaps = tracks.contains { $0.chapter != nil }
        cachedHasChapters = hasChaps

        // chapterGroups (only build if there are chapters to group)
        if hasChaps {
            var grouped: [String?: [AudiobookTrack]] = [:]
            for track in tracks {
                grouped[track.chapter, default: []].append(track)
            }
            let sortedKeys = grouped.keys.sorted { a, b in
                if a == nil { return false }
                if b == nil { return true }
                return a! < b!
            }
            cachedChapterGroups = sortedKeys.map { key in
                ChapterGroup(id: key ?? "ungrouped", chapter: key, tracks: grouped[key] ?? [])
            }
        } else {
            cachedChapterGroups = []
        }

        // totalTracksSize
        cachedTotalTracksSize = tracks.reduce(into: Int64(0)) { $0 += $1.fileSize }
    }

    /// Toggle chapter expanded/collapsed state
    func toggleChapterCollapsed(_ chapterId: String) {
        if expandedChapters.contains(chapterId) {
            expandedChapters.remove(chapterId)
        } else {
            expandedChapters.insert(chapterId)
        }
    }
    
    func isChapterCollapsed(_ chapterId: String) -> Bool {
        !expandedChapters.contains(chapterId)
    }
    
    /// Initialize chapter expand state: all collapsed except the one containing the current/last played track
    func initChapterExpandState(for collection: AudiobookCollection?) {
        guard !didInitChapterState else { return }
        didInitChapterState = true
        
        guard hasChapters else { return }
        
        // Find the focus track (current playing or last played)
        let focusTrackId = resolveAutoFocusTrackID(for: collection)
        
        guard let focusTrackId else {
            // No focus track — keep all collapsed
            return
        }
        
        // Find which chapter group contains this track and expand it
        for group in chapterGroups {
            if group.tracks.contains(where: { $0.id == focusTrackId }) {
                expandedChapters.insert(group.id)
                break
            }
        }
    }

    var showScrollToTopButton: Bool {
        !isSummaryVisible
    }
    
    // MARK: - Logic Methods
    
    func filterDBKey(for option: FilterOption) -> String {
        switch option {
        case .all: return "all"
        case .transcribed: return "transcribed"
        case .unplayed: return "unplayed"
        case .summarized: return "summarized"
        case .played: return "played"
        }
    }

    func sortDBKey(for criterion: SortCriterion, order: SortOrder) -> String {
        let base: String
        switch criterion {
        case .trackNumber: base = "trackNumber"
        case .title: base = "title"
        case .smartTitle: base = "title" // DB uses same column; smart sort is applied in-memory
        case .pubDate: base = "pubDate"
        }

        let suffix = order == .descending ? "Descending" : "Ascending"
        return base + suffix
    }

    func sortTracks(_ tracks: [AudiobookTrack], by criterion: SortCriterion, order: SortOrder) -> [AudiobookTrack] {
        let sorted: [AudiobookTrack]

        switch criterion {
        case .trackNumber:
            sorted = tracks.sorted { track1, track2 in
                if track1.trackNumber != track2.trackNumber {
                    return track1.trackNumber < track2.trackNumber
                }
                return track1.displayName.localizedStandardCompare(track2.displayName) == .orderedAscending
            }
        case .title:
            sorted = tracks.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .smartTitle:
            sorted = tracks.sorted {
                Self.smartTitleCompare($0.displayName, $1.displayName)
            }
        case .pubDate:
            sorted = tracks.sorted { track1, track2 in
                let date1 = Self.parsePubDate(from: track1.metadata["pubDate"])
                let date2 = Self.parsePubDate(from: track2.metadata["pubDate"])
                switch (date1, date2) {
                case (let d1?, let d2?):
                    return d1 < d2
                case (nil, _?):
                    return false  // No date goes to end
                case (_?, nil):
                    return true   // Has date comes before no date
                case (nil, nil):
                    return track1.trackNumber < track2.trackNumber  // Fallback to track number
                }
            }
        }

        return order == .descending ? sorted.reversed() : sorted
    }

    // MARK: - Smart Title Sort (Chinese Numeral Aware)

    /// Map of Chinese numeral characters to their numeric values.
    /// Supports 零-九 (0-9), 十百千万亿 for compound numbers like 二十三 (23).
    private static let chineseDigitValues: [Character: Int] = [
        "零": 0, "〇": 0,
        "一": 1, "壹": 1,
        "二": 2, "贰": 2, "两": 2,
        "三": 3, "叁": 3,
        "四": 4, "肆": 4,
        "五": 5, "伍": 5,
        "六": 6, "陆": 6,
        "七": 7, "柒": 7,
        "八": 8, "捌": 8,
        "九": 9, "玖": 9,
    ]

    private static let chineseMultiplierValues: [Character: Int] = [
        "十": 10, "拾": 10,
        "百": 100, "佰": 100,
        "千": 1000, "仟": 1000,
        "万": 10000,
        "亿": 100000000,
    ]

    /// Parses a Chinese numeral string (e.g. "二十三") into an integer (e.g. 23).
    /// Returns nil if the string contains no valid Chinese numerals.
    static func parseChineseNumeral(_ s: Substring) -> Int? {
        guard !s.isEmpty else { return nil }

        var result = 0
        var current = 0
        var hasNumeral = false

        for ch in s {
            if let digit = chineseDigitValues[ch] {
                current = digit
                hasNumeral = true
            } else if let multiplier = chineseMultiplierValues[ch] {
                hasNumeral = true
                if multiplier >= 10000 {
                    // 万/亿: multiply everything accumulated so far
                    result = (result + max(current, 1)) * multiplier
                    current = 0
                } else {
                    // 十/百/千: multiply current digit
                    if current == 0 && multiplier == 10 {
                        // Handle bare "十" meaning 10
                        current = 1
                    }
                    result += current * multiplier
                    current = 0
                }
            } else {
                return nil // non-Chinese-numeral character encountered
            }
        }

        result += current
        return hasNumeral ? result : nil
    }

    /// A sort key segment: either a string segment or a numeric value.
    private enum SortSegment: Comparable {
        case string(String)
        case number(Int)

        static func < (lhs: SortSegment, rhs: SortSegment) -> Bool {
            switch (lhs, rhs) {
            case (.number(let a), .number(let b)):
                return a < b
            case (.string(let a), .string(let b)):
                return a.localizedStandardCompare(b) == .orderedAscending
            case (.number, .string):
                return true // numbers sort before strings
            case (.string, .number):
                return false
            }
        }
    }

    /// Splits a title into segments for smart comparison.
    /// Recognizes Arabic digits AND Chinese numeral sequences, sorting them numerically.
    private static func smartTitleSegments(_ title: String) -> [SortSegment] {
        var segments: [SortSegment] = []
        var i = title.startIndex

        while i < title.endIndex {
            let ch = title[i]

            // Arabic digit run
            if ch.isASCII && ch.isNumber {
                let start = i
                while i < title.endIndex && title[i].isASCII && title[i].isNumber {
                    i = title.index(after: i)
                }
                let numStr = String(title[start..<i])
                segments.append(.number(Int(numStr) ?? 0))
                continue
            }

            // Chinese numeral run
            if chineseDigitValues[ch] != nil || chineseMultiplierValues[ch] != nil {
                let start = i
                while i < title.endIndex && (chineseDigitValues[title[i]] != nil || chineseMultiplierValues[title[i]] != nil) {
                    i = title.index(after: i)
                }
                let sub = title[start..<i]
                if let value = parseChineseNumeral(sub) {
                    segments.append(.number(value))
                } else {
                    segments.append(.string(String(sub)))
                }
                continue
            }

            // Regular character run
            let start = i
            while i < title.endIndex {
                let c = title[i]
                if (c.isASCII && c.isNumber) || chineseDigitValues[c] != nil || chineseMultiplierValues[c] != nil {
                    break
                }
                i = title.index(after: i)
            }
            segments.append(.string(String(title[start..<i])))
        }

        return segments
    }

    /// Compares two titles using smart segmentation (Chinese numeral + digit aware).
    static func smartTitleCompare(_ a: String, _ b: String) -> Bool {
        let segsA = smartTitleSegments(a)
        let segsB = smartTitleSegments(b)

        for (segA, segB) in zip(segsA, segsB) {
            if segA < segB { return true }
            if segB < segA { return false }
        }

        // If all compared segments are equal, shorter one comes first
        return segsA.count < segsB.count
    }

    static func parsePubDate(from string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    func scheduleSortedTracksUpdate() {
        sortTask?.cancel()

        if isPagedMode {
            Task { await reloadFromDatabase(startingPage: 0, focusTarget: pendingAutoFocusTrackId) }
            return
        }

        guard let collection else {
            cachedSortedTracks = []
            scheduleFilteredTracksUpdate()
            return
        }

        let tracks = collection.tracks
        let criterion = selectedCriterion
        let order = selectedOrder

        sortTask = Task.detached {
            let sorted = await self.sortTracks(tracks, by: criterion, order: order)
            if Task.isCancelled { return }
            await MainActor.run {
                self.cachedSortedTracks = sorted
                self.scheduleFilteredTracksUpdate()
            }
        }
    }

    func scheduleFilteredTracksUpdate() {
        filterTask?.cancel()

        if isPagedMode {
            Task {
                await reloadFromDatabase(startingPage: 0, focusTarget: pendingAutoFocusTrackId)
            }
            return
        }

        let base = sortedTracks
        let filter = selectedFilter
        let query = searchText
        let transcriptCache = transcriptStatusCache
        let summaryIds = tracksWithSummaries
        let collectionRef = collection

        filterTask = Task.detached {
            // Compute on a background thread
            let filtered = await self.computeOrderedTracks(from: base, filter: filter, query: query, transcriptCache: transcriptCache, summaryIds: summaryIds, collection: collectionRef)
            if Task.isCancelled { return }
            await MainActor.run {
                self.cachedOrderedTracks = filtered
                self.totalResults = filtered.count
                self.recomputeDerivedViewState()
            }
        }
    }

    func computeOrderedTracks(
        from base: [AudiobookTrack],
        filter: FilterOption,
        query: String,
        transcriptCache: [UUID: Bool],
        summaryIds: Set<UUID>,
        collection: AudiobookCollection?
    ) -> [AudiobookTrack] {
        var tracks = base
        
        // Always exclude archived tracks from main list
        tracks = tracks.filter { !$0.isArchived }

        if filter != .all {
            tracks = tracks.filter { track in
                switch filter {
                case .all:
                    return true
                case .transcribed:
                    return transcriptCache[track.id] == true
                case .unplayed:
                    let state = collection?.playbackState(for: track.id)
                    return state == nil || state!.position < 1
                case .summarized:
                    return summaryIds.contains(track.id)
                case .played:
                    if let state = collection?.playbackState(for: track.id) {
                        return state.position >= 1
                    }
                    return false
                }
            }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tracks }

        return tracks.filter { track in
            track.displayName.localizedCaseInsensitiveContains(trimmed) ||
            track.filename.localizedCaseInsensitiveContains(trimmed)
        }
    }
    
    // MARK: - Paging

    @MainActor
    func updateLoadedPages(_ page: Int, tracks: [AudiobookTrack]) {
        // Always exclude archived tracks from main list (matches non-paged path)
        loadedPages[page] = tracks.filter { !$0.isArchived }
        // Keep a small window to limit memory; always retain first page.
        let keep = [page - 1, page, page + 1, 0].filter { $0 >= 0 }
        loadedPages = loadedPages.filter { keep.contains($0.key) }
        cachedOrderedTracks = pagedTracks
        recomputeDerivedViewState()
    }

    func loadPage(_ page: Int) async {
        guard !loadingPages.contains(page) else { return }
        guard page >= 0 else { return }
        if totalPages > 0, page >= totalPages { return }
        guard let collection else { return }

        let queryToken = pagingQueryToken
        let query = currentQuery
        let filterKey = currentFilterKey
        let sortCriterion = currentSortCriterion
        let sortOrder = currentSortOrder

        _ = await MainActor.run { loadingPages.insert(page) }

        do {
            let offset = page * pageSize
            let (tracks, total) = try await GRDBDatabaseManager.shared.fetchTracks(
                collectionId: collection.id,
                query: query,
                filter: filterDBKey(for: filterKey),
                sort: sortDBKey(for: sortCriterion, order: sortOrder),
                offset: offset,
                limit: pageSize
            )

            let states = try await GRDBDatabaseManager.shared.fetchPlaybackStates(collectionId: collection.id, trackIds: tracks.map { $0.id })
            await MainActor.run {
                guard queryToken == self.pagingQueryToken else {
                    self.loadingPages.remove(page)
                    if page == 0 {
                        self.isListLoading = false
                    }
                    return
                }
                totalResults = total
                totalPages = Int(ceil(Double(totalResults) / Double(pageSize)))
                // Merge playback state snapshot for these tracks
                for (id, state) in states {
                    playbackStateSnapshot[id] = state
                }
                updateLoadedPages(page, tracks: tracks)
                // Remove from loading set BEFORE setting isListLoading = false
                // so that loadingPages.isEmpty is true when onChange handlers fire
                loadingPages.remove(page)
                if page == 0 {
                    isListLoading = false
                }
                // Refresh status caches for visible pages only
                loadTranscriptStatus()
                refreshTrackSummaryIndicators(for: collection)
            }
        } catch {
            AppLog.debug("[CollectionDetailViewModel] Failed to load page \(page): \(error)")
            await MainActor.run {
                if queryToken != self.pagingQueryToken {
                    self.loadingPages.remove(page)
                    if page == 0 {
                        self.isListLoading = false
                    }
                    return
                }
                loadingPages.remove(page)
                if page == 0 {
                    isListLoading = false
                }
            }
        }
    }

    @MainActor
    func resetPagingState(clearCaches: Bool = false) {
        loadedPages = [:]
        loadingPages = []
        totalPages = 0
        totalResults = 0
        if clearCaches {
            cachedOrderedTracks = []
            cachedSortedTracks = []
            recomputeDerivedViewState()
        }
    }

    func reloadFromDatabase(startingPage: Int, focusTarget: UUID?) async {
        await MainActor.run {
            isListLoading = true
        }

        resetPagingState(clearCaches: false)
        currentQuery = searchText
        currentFilterKey = selectedFilter
        currentSortCriterion = selectedCriterion
        currentSortOrder = selectedOrder
        pagingQueryToken = UUID()

        // Always load first page; we no longer preload neighbors to reduce jank.
        await loadPage(0)

        // Only attempt autofocus for non-paged collections; large collections skip it.
        await MainActor.run {
            pendingAutoFocusTrackId = isPagedMode ? nil : focusTarget
            didAutoFocusTrack = false
            isListLoading = false
        }
    }
    
    // MARK: - Actions & Logic
    
    func loadTranscriptStatus() {
        guard let collection else { return }

        transcriptStatusTask?.cancel()

        let tracks = isPagedMode ? pagedTracks : collection.tracks
        let trackIds = tracks.map { $0.id }

        transcriptStatusTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            guard !trackIds.isEmpty else {
                await MainActor.run {
                    self.transcriptStatusCache = [:]
                }
                return
            }

            let dbManager = GRDBDatabaseManager.shared

            do {
                let trackIdStrings = trackIds.map { $0.uuidString }
                var completedSet = Set<String>()

                let batchSize = 200
                var index = 0
                while index < trackIdStrings.count {
                    if Task.isCancelled { return }
                    let end = min(index + batchSize, trackIdStrings.count)
                    let batch = Array(trackIdStrings[index..<end])
                    let completedIds = try await dbManager.fetchTrackIdsWithCompletedTranscripts(trackIds: batch)
                    completedSet.formUnion(completedIds)
                    index = end
                }

                if Task.isCancelled { return }

                await MainActor.run {
                    var newCache: [UUID: Bool] = [:]
                    for track in tracks {
                        newCache[track.id] = completedSet.contains(track.id.uuidString)
                    }
                    self.transcriptStatusCache = newCache
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.transcriptStatusCache = [:]
                }
            }
        }
    }
    
    func confirmDeleteTranscript(_ track: AudiobookTrack) {
        guard !isEbookCollection else { return }
        trackPendingTranscriptDeletion = track
        showTranscriptDeletionDialog = true
    }

    func deleteTranscript(for track: AudiobookTrack) {
        showTranscriptDeletionDialog = false
        trackPendingTranscriptDeletion = nil

        Task {
            do {
                try await transcriptionManager?.deleteTranscript(forTrackId: track.id)
                await MainActor.run {
                    transcriptStatusCache[track.id] = false
                }
                loadTranscriptStatus()
            } catch {
                await MainActor.run {
                    transcriptDeletionError = error.localizedDescription
                    showTranscriptDeletionError = true
                }
            }
        }
    }
    
    func handleCroppedCoverImage(_ image: UIImage) {
        Task {
            do {
                guard let data = image.jpegData(compressionQuality: 0.95) else {
                    throw CollectionCoverImageStore.CoverError.encodingFailed
                }
                await applyCoverImageData(data)
            } catch {
                await MainActor.run {
                    coverUpdateError = error.localizedDescription
                    showCoverUpdateError = true
                }
            }
        }
    }

    func handleCoverFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            coverUpdateError = error.localizedDescription
            showCoverUpdateError = true
        case .success(let url):
            Task {
                let needsAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if needsAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let data = try Data(contentsOf: url)
                    await applyCoverImageData(data)
                } catch {
                    await MainActor.run {
                        coverUpdateError = error.localizedDescription
                        showCoverUpdateError = true
                    }
                }
            }
        }
    }

    func updatePlaybackProgress(
        trackID: UUID,
        position: TimeInterval,
        duration: TimeInterval?,
        forcePersist: Bool = false
    ) {
        let now = Date()
        library?.recordPlaybackProgress(
            collectionID: collectionID,
            trackID: trackID,
            position: position,
            duration: duration,
            forcePersist: forcePersist
        )

        var state = playbackStateSnapshot[trackID] ?? TrackPlaybackState(position: position, duration: duration, updatedAt: now)
        state.position = position
        if let duration {
            state.duration = duration
        }
        state.updatedAt = now
        playbackStateSnapshot[trackID] = state
    }

    func applyCoverImageData(_ data: Data) async {
        await MainActor.run {
            isUpdatingCover = true
        }

        do {
            try await library?.updateCollectionCover(collectionID: collectionID, imageData: data)
        } catch {
            await MainActor.run {
                coverUpdateError = error.localizedDescription
                showCoverUpdateError = true
            }
        }

        await MainActor.run {
            isUpdatingCover = false
        }
    }

    func resetCollectionCoverArtwork() {
        Task {
            await MainActor.run {
                isUpdatingCover = true
            }
            await library?.resetCollectionCover(collectionID: collectionID)
            await MainActor.run {
                isUpdatingCover = false
            }
        }
    }
    
    func refreshCollectionAction() {
        guard let collection = self.collection else { return }

        isRefreshingCollection = true
        Task {
            defer {
                Task { @MainActor in
                    self.isRefreshingCollection = false
                }
            }
            do {
                let candidates: [AudiobookTrack]
                switch collection.source {
                case .baiduNetdisk:
                    guard let token = authViewModel?.token else {
                        await MainActor.run {
                            missingAuthAlert = true
                        }
                        return
                    }
                    _ = try? await library?.syncBaiduTrackDescriptions(collectionId: collectionID, token: token)
                    candidates = try await library?.scanNewTracksForBaiduCollection(collectionId: collectionID, token: token) ?? []
                case .rss:
                    candidates = try await library?.scanNewTracksForRSSCollection(collectionId: collectionID) ?? []
                case .ebook(_, let bookmark):
                    var isStale = false
                    if let bookmark,
                       let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        
                        let parser = EpubParser()
                        let (_, _, chapters) = try parser.parse(epubURL: url)
                        
                        let existingNames = Set(collection.tracks.map { $0.filename })
                        let baseIndex = collection.trackCount
                        
                        // Re-do correctly
                        var newTracks: [AudiobookTrack] = []
                        var currentIndex = baseIndex
                        
                        for chapter in chapters {
                            if !existingNames.contains(chapter.filename) {
                                currentIndex += 1
                                newTracks.append(AudiobookTrack(
                                    id: UUID(),
                                    displayName: chapter.title,
                                    filename: chapter.filename,
                                    location: .text(content: chapter.content),
                                    fileSize: Int64(chapter.content.utf8.count),
                                    duration: nil,
                                    trackNumber: currentIndex,
                                    checksum: nil,
                                    metadata: [:],
                                    characterCount: chapter.content.count
                                ))
                            }
                        }
                        candidates = newTracks
                    } else {
                        candidates = []
                    }
                default:
                    return
                }
                
                if !candidates.isEmpty {
                    await MainActor.run {
                        isRefreshingCollection = false
                        candidateTracks = candidates
                        selectedCandidateIds = Set(candidates.map(\.id))
                        refreshReviewTitle = collection.title
                        refreshReviewDescription = collection.description ?? ""
                        showRefreshReview = true
                    }
                } else {
                    await MainActor.run {
                        refreshResult = NSLocalizedString("refresh_no_updates", value: "No new tracks found.", comment: "Refresh result: no updates")
                        showRefreshResult = true
                    }
                }
            } catch {
                await MainActor.run {
                    refreshResult = String(format: NSLocalizedString("refresh_failed_message", value: "Refresh failed: %@", comment: "Refresh failed message"), error.localizedDescription)
                    showRefreshResult = true
                }
            }
        }
    }
    
    func refreshSttTranscribingTrackIds(from jobs: [TranscriptionJob]) {
        let newIds = Set(
            jobs
                .filter { !$0.sonioxJobId.hasPrefix("tts-") }
                .compactMap { UUID(uuidString: $0.trackId) }
        )

        if newIds != sttTranscribingTrackIds {
            sttTranscribingTrackIds = newIds
        }
    }

    func refreshTTSGeneratingTrackIds(from jobs: [TranscriptionJob]) {
        let generatingStates: Set<String> = ["queued", "downloading", "uploading", "transcribing", "processing", "generating"]
        let newIds = Set(
            jobs
                .filter { generatingStates.contains($0.status) && $0.sonioxJobId.hasPrefix("tts-") }
                .compactMap { UUID(uuidString: $0.trackId) }
        )

        if newIds != ttsGeneratingTrackIds {
            ttsGeneratingTrackIds = newIds
        }
    }
    
    func refreshTrackSummaryIndicators(for collection: AudiobookCollection?) {
        summaryIndicatorTask?.cancel()

        guard let collection else {
            tracksWithSummaries = []
            summaryIndicatorTask = nil
            return
        }

        let trackIds: [String]
        if isPagedMode {
            trackIds = pagedTracks.map { $0.id.uuidString }
        } else {
            trackIds = collection.tracks.map { $0.id.uuidString }
        }
        guard !trackIds.isEmpty else {
            tracksWithSummaries = []
            summaryIndicatorTask = nil
            return
        }

        let task = Task.detached { [trackIds] in
            // Debounce: wait 500ms before querying
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if Task.isCancelled { return }

            var readyTrackIds = Set<UUID>()
            do {
                let batchSize = 500
                var completedStrings: Set<String> = []
                var index = 0
                while index < trackIds.count {
                    if Task.isCancelled { return }
                    let end = min(index + batchSize, trackIds.count)
                    let batch = Array(trackIds[index..<end])
                    let completedIds = try await GRDBDatabaseManager.shared.fetchTrackIdsWithCompletedSummaries(trackIds: batch)
                    completedStrings.formUnion(completedIds)
                    index = end
                }
                readyTrackIds = Set(completedStrings.compactMap { UUID(uuidString: $0) })
            } catch {
                AppLog.debug("[CollectionDetailViewModel] Failed to refresh summary indicators: \(error.localizedDescription)")
            }
            
            if Task.isCancelled { return }

            await MainActor.run {
                self.tracksWithSummaries = readyTrackIds
            }
        }

        summaryIndicatorTask = task
    }
    
    func prepareAutoFocusTargetIfNeeded(for collection: AudiobookCollection?) {
        guard !didAutoFocusTrack else { return }

        guard let target = resolveAutoFocusTrackID(for: collection) else {
            if pendingAutoFocusTrackId != nil {
                pendingAutoFocusTrackId = nil
            }
            return
        }

        if pendingAutoFocusTrackId != target {
            pendingAutoFocusTrackId = target
        }
    }

    func resetAutoFocusState() {
        pendingAutoFocusTrackId = nil
        didAutoFocusTrack = false
    }

    func refreshPlaybackStateSnapshot(for collection: AudiobookCollection?) {
        guard let collection else {
            playbackStateSnapshot = [:]
            return
        }
        playbackStateSnapshot = collection.playbackStates
    }

    func resolveAutoFocusTrackID(for collection: AudiobookCollection?) -> UUID? {
        guard let collection else { return nil }

        // Active track: must exist and not be archived (archived items are filtered from list,
        // so scrolling to their id would land at a stale position).
        if
            audioPlayer?.activeCollection?.id == collection.id,
            let activeId = audioPlayer?.currentTrack?.id,
            collection.tracks.contains(where: { $0.id == activeId && !$0.isArchived })
        {
            return activeId
        }

        // Last played fallback: if archived, jump to the next non-archived sibling.
        if let lastPlayed = collection.lastPlayedTrackId,
           let lastIndex = collection.tracks.firstIndex(where: { $0.id == lastPlayed })
        {
            if !collection.tracks[lastIndex].isArchived {
                return lastPlayed
            }
            if let next = collection.tracks[(lastIndex + 1)...].first(where: { !$0.isArchived }) {
                return next.id
            }
        }

        return nil
    }
    
    func startPlayback(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        if audioPlayer?.currentTrack?.id == track.id, audioPlayer?.isPlaying == true {
            audioPlayer?.togglePlayback()
        } else {
            audioPlayer?.play(track: track, in: collection, token: authViewModel?.token)
            recordPlayback(for: collection, track: track, position: audioPlayer?.currentTime ?? 0)
        }
    }
    
    func recordPlayback(for collection: AudiobookCollection, track: AudiobookTrack, position: Double) {
        library?.recordPlaybackProgress(
            collectionID: collection.id,
            trackID: track.id,
            position: position,
            duration: audioPlayer?.duration ?? 0
        )
    }

    func isCurrentTrack(track: AudiobookTrack) -> Bool {
        audioPlayer?.currentTrack?.id == track.id && audioPlayer?.activeCollection?.id == collectionID
    }

    func hasNextTrack(_ track: AudiobookTrack) -> Bool {
        nextTrack(after: track) != nil
    }

    func hasPreviousTrack(_ track: AudiobookTrack) -> Bool {
        previousTrack(before: track) != nil
    }
    
    func previousTrack(before track: AudiobookTrack) -> AudiobookTrack? {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return nil
        }
        guard index > sortedTracks.startIndex else {
            return nil
        }
        let previousIndex = sortedTracks.index(before: index)
        return sortedTracks[previousIndex]
    }

    func nextTrack(after track: AudiobookTrack) -> AudiobookTrack? {
        guard let index = sortedTracks.firstIndex(where: { $0.id == track.id }) else {
            return nil
        }
        let nextIndex = sortedTracks.index(after: index)
        guard sortedTracks.indices.contains(nextIndex) else {
            return nil
        }
        return sortedTracks[nextIndex]
    }
    
    func handlePlayPause(for track: AudiobookTrack, in collection: AudiobookCollection) {
        if audioPlayer?.hasActivePlayer == true, audioPlayer?.currentTrack?.id == track.id {
            audioPlayer?.togglePlayback()
        } else {
            startPlayback(track, in: collection)
        }
    }

    func handlePreviousButton(for track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let target = previousTrack(before: track) else { return }
        if audioPlayer?.hasActivePlayer == true, audioPlayer?.currentTrack?.id == track.id {
            audioPlayer?.playPreviousTrack()
        } else {
            startPlayback(target, in: collection)
        }
    }

    func handleNextButton(for track: AudiobookTrack, in collection: AudiobookCollection) {
        guard let target = nextTrack(after: track) else { return }
        if audioPlayer?.hasActivePlayer == true, audioPlayer?.currentTrack?.id == track.id {
            audioPlayer?.playNextTrack()
        } else {
            startPlayback(target, in: collection)
        }
    }

    func confirmDeleteTrack(_ track: AudiobookTrack) {
        trackToDelete = track
        showDeleteConfirmation = true
    }

    func beginRenamingTrack(_ track: AudiobookTrack) {
        trackToRename = track
        trackTitleDraft = String(track.displayName.prefix(256))
    }

    func cancelTrackRename() {
        trackToRename = nil
        trackTitleDraft = ""
    }

    func applyTrackRename(for track: AudiobookTrack) {
        let trimmed = trackTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        trackTitleDraft = ""
        trackToRename = nil

        guard !trimmed.isEmpty else { return }
        library?.renameTrack(
            in: collectionID,
            trackID: track.id,
            newTitle: String(trimmed.prefix(256))
        )
    }

    func beginEditingCollectionDetails(_ collection: AudiobookCollection) {
        collectionTitleDraft = String(collection.title.prefix(256))
        collectionDescriptionDraft = String((collection.description ?? "").prefix(1024))
        collectionIsMusicDraft = collection.isMusic
        collectionAutoUpdateEnabledDraft = collection.autoUpdateEnabled

        // Extract folder path if this is a Baidu Netdisk collection
        if case let .baiduNetdisk(folderPath, _) = collection.source {
            collectionFolderPathDraft = folderPath
        } else {
            collectionFolderPathDraft = nil
        }

        showCollectionInfoSheet = true
    }

    func cancelCollectionDetailsEdit() {
        showCollectionInfoSheet = false
        collectionTitleDraft = ""
        collectionDescriptionDraft = ""
        collectionFolderPathDraft = nil
    }

    func applyCollectionDetailsUpdate() {
        guard let collection else {
            cancelCollectionDetailsEdit()
            return
        }

        let trimmedTitle = collectionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = collectionDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPathDraft = collectionFolderPathDraft

        collectionTitleDraft = ""
        collectionDescriptionDraft = ""
        collectionFolderPathDraft = nil
        showCollectionInfoSheet = false

        guard !trimmedTitle.isEmpty else { return }

        let clampedTitle = String(trimmedTitle.prefix(256))
        let clampedDescription = trimmedDescription.isEmpty ? nil : String(trimmedDescription.prefix(1024))

        // Determine if folder path changed (for Baidu Netdisk collections)
        var newSource: AudiobookCollection.Source? = nil
        if case let .baiduNetdisk(oldPath, tokenScope) = collection.source,
           let newPath = folderPathDraft?.trimmingCharacters(in: .whitespacesAndNewlines),
           !newPath.isEmpty,
           newPath != oldPath {
            newSource = .baiduNetdisk(folderPath: newPath, tokenScope: tokenScope)
        }

        guard clampedTitle != collection.title || clampedDescription != collection.description || collectionIsMusicDraft != collection.isMusic || newSource != nil || collectionAutoUpdateEnabledDraft != collection.autoUpdateEnabled else { return }

        if collectionAutoUpdateEnabledDraft != collection.autoUpdateEnabled {
            library?.updateAutoUpdateEnabled(collectionAutoUpdateEnabledDraft, for: collectionID)
        }

        library?.updateCollectionDetails(
            collectionID: collectionID,
            newTitle: clampedTitle,
            newDescription: clampedDescription,
            shouldUpdateDescription: true,
            isMusic: collectionIsMusicDraft,
            newSource: newSource
        )
    }

    func deleteSelectedTrack() {
        guard let track = trackToDelete else { return }
        library?.removeTrackFromCollection(
            collectionID: collectionID,
            trackID: track.id
        )
        trackToDelete = nil
    }

    func addTracksAction() {
        if let source = collection?.source {
            AppLog.debug("[CollectionDetailViewModel] addTracksAction source: \(source)")
            switch source {
            case .rss:
                return // RSS does not support manual track addition
            case .ebook:
                AppLog.debug("[CollectionDetailViewModel] Toggling showEbookFileImporter")
                showEbookFileImporter = true
                return
            default:
                break
            }
        }
        AppLog.debug("[CollectionDetailViewModel] Showing TrackPicker")
        showTrackPicker = true
    }

    func handleEbookFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            ebookImportError = error.localizedDescription
        case .success(let url):
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    let parser = EpubParser()
                    let (_, _, chapters) = try parser.parse(epubURL: url)
                    
                    let baseIndex = collection?.trackCount ?? 0
                    
                    let newTracks = chapters.enumerated().map { index, chapter in
                        AudiobookTrack(
                            id: UUID(),
                            displayName: chapter.title,
                            filename: chapter.filename,
                            location: .text(content: chapter.content),
                            fileSize: Int64(chapter.content.utf8.count),
                            duration: nil,
                            trackNumber: baseIndex + index + 1,
                            checksum: nil,
                            metadata: [:],
                            characterCount: chapter.content.count
                        )
                    }
                    
                    if !newTracks.isEmpty {
                        await MainActor.run {
                            isRefreshingCollection = false
                            candidateTracks = newTracks
                            selectedCandidateIds = Set(newTracks.map(\.id))
                            refreshReviewTitle = collection?.title ?? ""
                            refreshReviewDescription = collection?.description ?? ""
                            showRefreshReview = true
                        }
                    }
                } catch {
                    await MainActor.run {
                        ebookImportError = error.localizedDescription
                    }
                }
            }
        }
    }
    
    func removePrompt(for track: AudiobookTrack) -> String {
        let template = NSLocalizedString("remove_track_prompt", comment: "Remove track confirmation prompt")
        return template.replacingOccurrences(of: "{{name}}", with: track.displayName)
    }
    
    // MARK: - Enums
    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case transcribed = "Transcribed"
        case unplayed = "Unplayed"
        case summarized = "Summarized"
        case played = "Played"
        
        var id: String { rawValue }
        
        var localizedName: String {
            switch self {
            case .all: return NSLocalizedString("filter_all", value: "All", comment: "Filter option: All")
            case .transcribed: return NSLocalizedString("filter_transcribed", value: "已转录", comment: "Filter option: Transcribed")
            case .unplayed: return NSLocalizedString("filter_unplayed", value: "未播放", comment: "Filter option: Unplayed")
            case .summarized: return NSLocalizedString("filter_summarized", value: "已总结", comment: "Filter option: Summarized")
            case .played: return NSLocalizedString("filter_played", value: "播放过", comment: "Filter option: Played")
            }
        }
        
        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .transcribed: return "text.bubble"
            case .unplayed: return "circle"
            case .summarized: return "doc.text"
            case .played: return "play.circle"
            }
        }
    }

    enum SortCriterion: String, CaseIterable, Identifiable {
        case trackNumber = "Track Number"
        case title = "Title"
        case smartTitle = "Smart Title"
        case pubDate = "Pub Date"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .trackNumber: return NSLocalizedString("sort_track_number", value: "Track Number", comment: "Sort criterion: Track Number")
            case .title: return NSLocalizedString("sort_title", value: "Title", comment: "Sort criterion: Title")
            case .smartTitle: return NSLocalizedString("sort_smart_title", value: "Smart Title (中文)", comment: "Sort criterion: Smart Title with Chinese numeral support")
            case .pubDate: return NSLocalizedString("sort_pubdate", value: "Pub Date", comment: "Sort criterion: Pub Date")
            }
        }

        var icon: String {
            switch self {
            case .trackNumber: return "list.number"
            case .title: return "textformat"
            case .smartTitle: return "character.textbox"
            case .pubDate: return "calendar"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case ascending = "Ascending"
        case descending = "Descending"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .ascending: return NSLocalizedString("sort_ascending", value: "Ascending", comment: "Sort order: Ascending")
            case .descending: return NSLocalizedString("sort_descending", value: "Descending", comment: "Sort order: Descending")
            }
        }

        var icon: String {
            switch self {
            case .ascending: return "arrow.up"
            case .descending: return "arrow.down"
            }
        }
    }
}
