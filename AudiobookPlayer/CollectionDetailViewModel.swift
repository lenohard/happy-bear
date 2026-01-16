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

    var showScrollToTopButton: Bool {
        !isSummaryVisible
    }

    var showScrollToBottomButton: Bool {
        guard !isPagedMode else { return false }
        guard !filteredTracks.isEmpty else { return false }
        return !isLastTrackVisible
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
        loadedPages[page] = tracks
        // Keep a small window to limit memory; always retain first page.
        let keep = [page - 1, page, page + 1, 0].filter { $0 >= 0 }
        loadedPages = loadedPages.filter { keep.contains($0.key) }
        cachedOrderedTracks = pagedTracks
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
        duration: TimeInterval?
    ) {
        let now = Date()
        library?.recordPlaybackProgress(
            collectionID: collectionID,
            trackID: trackID,
            position: position,
            duration: duration
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

        if
            audioPlayer?.activeCollection?.id == collection.id,
            let activeId = audioPlayer?.currentTrack?.id,
            collection.tracks.contains(where: { $0.id == activeId })
        {
            return activeId
        }

        if
            let lastPlayed = collection.lastPlayedTrackId,
            collection.tracks.contains(where: { $0.id == lastPlayed })
        {
            return lastPlayed
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
        case pubDate = "Pub Date"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .trackNumber: return NSLocalizedString("sort_track_number", value: "Track Number", comment: "Sort criterion: Track Number")
            case .title: return NSLocalizedString("sort_title", value: "Title", comment: "Sort criterion: Title")
            case .pubDate: return NSLocalizedString("sort_pubdate", value: "Pub Date", comment: "Sort criterion: Pub Date")
            }
        }

        var icon: String {
            switch self {
            case .trackNumber: return "list.number"
            case .title: return "textformat"
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
