import Foundation

/// A single entry in a listen queue.
///
/// An item is *either* a pointer at a specific track or a reference to a whole
/// collection. Collection-type items expand to tracks at play time (see
/// `ListenQueueStore.nextPendingTrack`), so newly added tracks inside the
/// collection are naturally included without pre-materialising queue rows.
struct ListenQueueItem: Identifiable, Equatable, Hashable {
    enum Target: Equatable, Hashable {
        case track(collectionID: UUID, trackID: UUID)
        case collection(collectionID: UUID)

        var collectionID: UUID {
            switch self {
            case .track(let c, _): return c
            case .collection(let c): return c
            }
        }

        var trackID: UUID? {
            switch self {
            case .track(_, let t): return t
            case .collection: return nil
            }
        }

        var kindRaw: String {
            switch self {
            case .track: return "track"
            case .collection: return "collection"
            }
        }
    }

    enum Status: String, Codable {
        case pending
        case completed
        case skipped
    }

    let id: UUID
    let listID: UUID
    let target: Target
    var position: Double
    var status: Status
    var addedAt: Date
    var completedAt: Date?
    var note: String?

    init(
        id: UUID = UUID(),
        listID: UUID,
        target: Target,
        position: Double,
        status: Status = .pending,
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.listID = listID
        self.target = target
        self.position = position
        self.status = status
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.note = note
    }

    var isTrackTarget: Bool {
        if case .track = target { return true }
        return false
    }

    var isCollectionTarget: Bool {
        if case .collection = target { return true }
        return false
    }
}
