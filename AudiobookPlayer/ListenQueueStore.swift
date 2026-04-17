import Foundation
import Combine

// MARK: - ListenQueueStore
//
// @MainActor ObservableObject that owns the Listen Queue state.
// Mirrors the style of `LibraryStore` — hydrated @Published snapshots, mutations go
// through `GRDBDatabaseManager` and re-publish.
//
// Only the built-in default list is used in v1; multi-list support lives in the schema
// for future expansion without migration.

@MainActor
final class ListenQueueStore: ObservableObject {

    // MARK: Resolved projection for UI

    /// A queue item hydrated against the current LibraryStore snapshot.
    struct ResolvedItem: Identifiable, Equatable {
        let item: ListenQueueItem
        let collection: AudiobookCollection?
        let track: AudiobookTrack?           // nil for collection-target or if missing
        let isMissing: Bool                  // true if referenced IDs not found in library
        let progress: Double?                // 0..1 for track targets with playback state
        let remainingTracks: Int?            // for collection targets — unplayed count

        var id: UUID { item.id }

        var displayTitle: String {
            if isMissing { return "(no longer available)" }
            if let track {
                return track.displayName
            }
            if let collection {
                return collection.title
            }
            return "(missing)"
        }

        var displaySubtitle: String? {
            if let track, let collection {
                return collection.title
            }
            if collection != nil {
                return "Collection"
            }
            return nil
        }
    }

    // MARK: Published state

    @Published private(set) var pendingItems: [ListenQueueItem] = []
    @Published private(set) var completedItems: [ListenQueueItem] = []

    /// Hydrated UI views, refreshed whenever items or the library change.
    @Published private(set) var resolvedPending: [ResolvedItem] = []
    @Published private(set) var resolvedCompleted: [ResolvedItem] = []

    /// When ON, `AudioPlayerViewModel.playNextTrack()` will prefer the queue over the
    /// current collection's auto-advance. Persisted in UserDefaults.
    @Published var playFromQueueEnabled: Bool {
        didSet { UserDefaults.standard.set(playFromQueueEnabled, forKey: Self.playFromQueueKey) }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: Error?

    // MARK: Dependencies

    private let dbManager: GRDBDatabaseManager
    private weak var library: LibraryStore?
    private var libraryObserver: AnyCancellable?

    private static let playFromQueueKey = "listen_queue_play_from_queue_enabled"
    private static let completedCap = 200
    private static let listIDString = ListenQueueDatabaseSchema.defaultListID

    /// Default list UUID (matches the hardcoded schema seed row).
    private var defaultListID: UUID {
        UUID(uuidString: Self.listIDString) ?? UUID()
    }

    // MARK: Init

    init(dbManager: GRDBDatabaseManager = .shared, autoLoadOnInit: Bool = true) {
        self.dbManager = dbManager
        self.playFromQueueEnabled = UserDefaults.standard.bool(forKey: Self.playFromQueueKey)
        if autoLoadOnInit {
            Task(priority: .userInitiated) { [weak self] in
                await self?.load()
            }
        }
    }

    // MARK: Library binding

    /// Connect to a LibraryStore so the store can produce resolved items and react to
    /// library changes (collection deletes, track updates).
    func bindLibrary(_ library: LibraryStore) {
        self.library = library
        libraryObserver?.cancel()
        libraryObserver = library.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Debounce-free; objectWillChange is infrequent enough. The refresh is cheap.
                Task { @MainActor [weak self] in
                    self?.refreshResolved()
                }
            }
        refreshResolved()
    }

    // MARK: Load

    /// Loads pending + completed items from the DB, ensures the default list row exists,
    /// and refreshes resolved projections.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await dbManager.initializeDatabase()
            // The schema/seed SQL is run in initializeDatabase, but ensureDefault is cheap & safe.
            try await dbManager.ensureDefaultQueueListExists()

            let pending = try await dbManager.fetchQueueItems(
                listID: Self.listIDString,
                status: .pending,
                limit: nil
            )
            let completed = try await dbManager.fetchQueueItems(
                listID: Self.listIDString,
                status: .completed,
                limit: Self.completedCap
            )
            self.pendingItems = pending
            self.completedItems = completed
            self.lastError = nil
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] load failed: \(error)")
            self.lastError = error
        }
    }

    // MARK: Queries

    /// True if a *pending* queue item exists for this track in the default list.
    func isQueued(trackID: UUID) -> Bool {
        pendingItems.contains { item in
            if case .track(_, let id) = item.target { return id == trackID }
            return false
        }
    }

    /// True if a *pending* queue item exists for this collection in the default list.
    func isQueued(collectionID: UUID) -> Bool {
        pendingItems.contains { item in
            if case .collection(let id) = item.target { return id == collectionID }
            return false
        }
    }

    /// Returns the first resolved (collection, track) pair the user should hear next.
    /// - Skips `missing` items (but leaves them in the queue for the user to see).
    /// - For collection-target items, picks the first track in the collection's preferred
    ///   sort order that isn't "done" (neither completed in queue nor played ≥95%).
    /// - For collection items whose remaining tracks are all "done", auto-marks that
    ///   queue row completed and recurses.
    func nextPendingTrack() -> (AudiobookCollection, AudiobookTrack)? {
        guard let library else { return nil }
        for item in pendingItems {
            switch item.target {
            case .track(let collectionID, let trackID):
                guard
                    let collection = library.collections.first(where: { $0.id == collectionID }),
                    let track = collection.tracks.first(where: { $0.id == trackID })
                else { continue }
                return (collection, track)
            case .collection(let collectionID):
                guard let collection = library.collections.first(where: { $0.id == collectionID }) else {
                    continue
                }
                if let track = firstUnfinishedTrack(in: collection) {
                    return (collection, track)
                } else {
                    // All tracks already finished — auto-complete this queue row.
                    Task { [weak self] in await self?.markDone(itemID: item.id) }
                    continue
                }
            }
        }
        return nil
    }

    // MARK: Mutations

    /// Add a single track to the pending queue. No-op if already pending.
    @discardableResult
    func addTrack(_ trackID: UUID, in collectionID: UUID, note: String? = nil) async -> Bool {
        await addItem(target: .track(collectionID: collectionID, trackID: trackID), note: note)
    }

    /// Add an entire collection to the pending queue. No-op if already pending.
    @discardableResult
    func addCollection(_ collectionID: UUID, note: String? = nil) async -> Bool {
        await addItem(target: .collection(collectionID: collectionID), note: note)
    }

    /// Remove an item entirely (both pending and completed).
    func remove(itemID: UUID) async {
        do {
            try await dbManager.deleteQueueItem(id: itemID)
            pendingItems.removeAll { $0.id == itemID }
            completedItems.removeAll { $0.id == itemID }
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] remove failed: \(error)")
            lastError = error
        }
    }

    /// Mark a queue item as completed. Idempotent.
    func markDone(itemID: UUID) async {
        guard var item = pendingItems.first(where: { $0.id == itemID }) else {
            // Already completed or unknown — nothing to do.
            return
        }
        item.status = .completed
        item.completedAt = Date()
        do {
            try await dbManager.updateQueueItem(item)
            pendingItems.removeAll { $0.id == itemID }
            // Prepend so most-recently-completed is at the top of the Completed tab.
            completedItems.insert(item, at: 0)
            if completedItems.count > Self.completedCap {
                completedItems = Array(completedItems.prefix(Self.completedCap))
            }
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] markDone failed: \(error)")
            lastError = error
        }
    }

    /// Move a completed item back into pending (appended at the end).
    func unmarkDone(itemID: UUID) async {
        guard var item = completedItems.first(where: { $0.id == itemID }) else { return }
        item.status = .pending
        item.completedAt = nil
        item.position = nextAppendPosition()
        do {
            try await dbManager.updateQueueItem(item)
            completedItems.removeAll { $0.id == itemID }
            pendingItems.append(item)
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] unmarkDone failed: \(error)")
            lastError = error
        }
    }

    /// Move a pending item to a new index in the pending list (user drag reorder).
    /// Uses fractional positions to avoid rewriting every row.
    func move(itemID: UUID, to newIndex: Int) async {
        guard let currentIndex = pendingItems.firstIndex(where: { $0.id == itemID }) else { return }
        // Compute the neighbors the item will sit between *after* the move.
        // Build a temp reordered array to read neighbors from.
        var reordered = pendingItems
        let item = reordered.remove(at: currentIndex)
        let insertAt = max(0, min(newIndex, reordered.count))
        reordered.insert(item, at: insertAt)

        let before = insertAt > 0 ? reordered[insertAt - 1].position : nil
        let after = (insertAt + 1) < reordered.count ? reordered[insertAt + 1].position : nil

        let newPos: Double
        switch (before, after) {
        case (nil, nil):
            newPos = 1.0
        case (let b?, nil):
            newPos = b + 1.0
        case (nil, let a?):
            newPos = a - 1.0
        case (let b?, let a?):
            newPos = (b + a) / 2.0
        }

        var updated = item
        updated.position = newPos
        do {
            try await dbManager.updateQueueItem(updated)
            pendingItems = reordered.map { $0.id == itemID ? updated : $0 }
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] move failed: \(error)")
            lastError = error
        }
    }

    /// Wipe completed history (optionally only rows older than `olderThan`).
    func clearCompleted(olderThan: Date? = nil) async {
        do {
            try await dbManager.deleteCompletedQueueItems(
                listID: Self.listIDString,
                olderThan: olderThan
            )
            if let olderThan {
                completedItems.removeAll { ($0.completedAt ?? .distantPast) < olderThan }
            } else {
                completedItems.removeAll()
            }
            refreshResolved()
        } catch {
            AppLog.debug("[QUEUE] clearCompleted failed: \(error)")
            lastError = error
        }
    }

    // MARK: Auto-complete hook (called from AudioPlayerViewModel)

    /// Called by the audio player when a track finishes (natural end or ≥95% scrub-through).
    /// Flips matching pending queue rows to completed:
    /// 1. direct track-target row for this track,
    /// 2. collection-target row whose last remaining unplayed track was this one.
    func handleTrackFinished(trackID: UUID, collectionID: UUID) async {
        // 1) Track-target match
        if let item = pendingItems.first(where: { item in
            if case .track(_, let tid) = item.target { return tid == trackID }
            return false
        }) {
            AppLog.debug("[QUEUE] auto-completed track item \(item.id) for track \(trackID)")
            await markDone(itemID: item.id)
        }

        // 2) Collection-target match — only complete when this was the last unplayed track.
        guard let library else { return }
        guard let collection = library.collections.first(where: { $0.id == collectionID }) else { return }
        for item in pendingItems {
            guard case .collection(let cid) = item.target, cid == collectionID else { continue }
            // Treat THIS just-finished track as done even if the playbackState hasn't
            // updated yet, so we don't miss the last-track-of-collection case.
            if firstUnfinishedTrack(in: collection, pretendingFinished: trackID) == nil {
                AppLog.debug("[QUEUE] auto-completed collection item \(item.id) (all tracks done)")
                await markDone(itemID: item.id)
            }
        }
    }

    // MARK: - Internals

    private func addItem(target: ListenQueueItem.Target, note: String?) async -> Bool {
        // Fast path: if an equivalent pending row already exists locally, bail.
        if alreadyPending(target) {
            AppLog.debug("[QUEUE] add skipped — already pending: \(target)")
            return false
        }
        let item = ListenQueueItem(
            id: UUID(),
            listID: defaultListID,
            target: target,
            position: nextAppendPosition(),
            status: .pending,
            addedAt: Date(),
            completedAt: nil,
            note: note
        )
        do {
            let inserted = try await dbManager.insertQueueItem(item)
            if inserted {
                pendingItems.append(item)
                refreshResolved()
                return true
            } else {
                // DB rejected via unique index — refresh from DB to stay consistent.
                await load()
                return false
            }
        } catch {
            AppLog.debug("[QUEUE] add failed: \(error)")
            lastError = error
            return false
        }
    }

    private func alreadyPending(_ target: ListenQueueItem.Target) -> Bool {
        switch target {
        case .track(_, let trackID): return isQueued(trackID: trackID)
        case .collection(let cid): return isQueued(collectionID: cid)
        }
    }

    private func nextAppendPosition() -> Double {
        (pendingItems.map { $0.position }.max() ?? 0) + 1.0
    }

    /// Rebuilds `resolvedPending` / `resolvedCompleted` from the current library snapshot.
    func refreshResolved() {
        resolvedPending = pendingItems.map { resolve($0) }
        resolvedCompleted = completedItems.map { resolve($0) }
    }

    private func resolve(_ item: ListenQueueItem) -> ResolvedItem {
        let collection = library?.collections.first(where: { $0.id == item.target.collectionID })
        switch item.target {
        case .track(_, let trackID):
            let track = collection?.tracks.first(where: { $0.id == trackID })
            let missing = (collection == nil) || (track == nil)
            let progress = trackProgress(collection: collection, trackID: trackID)
            return ResolvedItem(
                item: item,
                collection: collection,
                track: track,
                isMissing: missing,
                progress: progress,
                remainingTracks: nil
            )
        case .collection:
            let missing = collection == nil
            let remaining = collection.map { remainingTrackCount(in: $0) }
            return ResolvedItem(
                item: item,
                collection: collection,
                track: nil,
                isMissing: missing,
                progress: nil,
                remainingTracks: remaining
            )
        }
    }

    private func trackProgress(collection: AudiobookCollection?, trackID: UUID) -> Double? {
        guard let collection else { return nil }
        guard let state = collection.playbackState(for: trackID) else { return nil }
        guard let duration = state.duration, duration > 0 else { return nil }
        return min(max(state.position / duration, 0), 1)
    }

    /// Returns the first track in the collection (using preferred sort order) that isn't
    /// considered "done" (not ≥95% played and not in our own completed set).
    /// Optionally treat `pretendingFinished` as if it was just completed.
    /// Returns the first track in `collection` (in preferred order) that is not
    /// yet queue-completed and has played less than 95% of its duration.
    /// Exposed for views that need to resolve a collection-target into a concrete track.
    func firstUnfinishedTrack(
        in collection: AudiobookCollection,
        pretendingFinished finishedTrackID: UUID? = nil
    ) -> AudiobookTrack? {
        let completedTrackIDs = Set(completedItems.compactMap { item -> UUID? in
            if case .track(_, let id) = item.target { return id }
            return nil
        })
        for track in collection.tracksSortedByPreferredOrder {
            if let finishedTrackID, track.id == finishedTrackID { continue }
            if completedTrackIDs.contains(track.id) { continue }
            if let state = collection.playbackState(for: track.id),
               let duration = state.duration, duration > 0,
               state.position >= 0.95 * duration {
                continue
            }
            return track
        }
        return nil
    }

    private func remainingTrackCount(in collection: AudiobookCollection) -> Int {
        let completedTrackIDs = Set(completedItems.compactMap { item -> UUID? in
            if case .track(_, let id) = item.target { return id }
            return nil
        })
        var count = 0
        for track in collection.tracks {
            if completedTrackIDs.contains(track.id) { continue }
            if let state = collection.playbackState(for: track.id),
               let duration = state.duration, duration > 0,
               state.position >= 0.95 * duration {
                continue
            }
            count += 1
        }
        return count
    }
}
