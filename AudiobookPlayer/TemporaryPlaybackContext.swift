import Foundation

struct TemporaryPlaybackContext: Identifiable, Equatable {
    let id: UUID
    let sourcePath: String
    let sourceDirectory: String
    let createdAt: Date
    let collection: AudiobookCollection

    init(
        title: String,
        sourcePath: String,
        tracks: [AudiobookTrack],
        author: String? = nil,
        cover: CollectionCover = CollectionCover(kind: .solid(colorHex: "#5B8DEF"), dominantColorHex: nil)
    ) {
        let now = Date()
        let directoryPath = (sourcePath as NSString).deletingLastPathComponent
        let normalizedDirectory = directoryPath.isEmpty ? "/" : directoryPath
        let collectionId = UUID()

        self.id = collectionId
        self.sourcePath = sourcePath
        self.sourceDirectory = normalizedDirectory
        self.createdAt = now
        self.collection = AudiobookCollection(
            id: collectionId,
            title: title,
            author: author,
            description: nil,
            coverAsset: cover,
            createdAt: now,
            updatedAt: now,
            source: .ephemeralBaidu(path: sourcePath),
            tracks: tracks,
            lastPlayedTrackId: tracks.first?.id,
            playbackStates: [:],
            tags: []
        )
    }
}
