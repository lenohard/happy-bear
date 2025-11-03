import Foundation

struct TrackPlaybackState: Codable, Equatable {
    var position: TimeInterval
    var duration: TimeInterval?
    var updatedAt: Date
}

struct AudiobookCollection: Identifiable, Codable, Equatable {
    enum Source: Codable, Equatable {
        case baiduNetdisk(folderPath: String, tokenScope: String)
        case local(directoryBookmark: Data)
        case external(description: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case folderPath
            case tokenScope
            case directoryBookmark
            case description
        }

        private enum SourceType: String, Codable {
            case baiduNetdisk
            case local
            case external
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(SourceType.self, forKey: .type)

            switch type {
            case .baiduNetdisk:
                let folderPath = try container.decode(String.self, forKey: .folderPath)
                let tokenScope = try container.decode(String.self, forKey: .tokenScope)
                self = .baiduNetdisk(folderPath: folderPath, tokenScope: tokenScope)
            case .local:
                let bookmark = try container.decode(Data.self, forKey: .directoryBookmark)
                self = .local(directoryBookmark: bookmark)
            case .external:
                let description = try container.decode(String.self, forKey: .description)
                self = .external(description: description)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .baiduNetdisk(folderPath, tokenScope):
                try container.encode(SourceType.baiduNetdisk, forKey: .type)
                try container.encode(folderPath, forKey: .folderPath)
                try container.encode(tokenScope, forKey: .tokenScope)
            case let .local(directoryBookmark):
                try container.encode(SourceType.local, forKey: .type)
                try container.encode(directoryBookmark, forKey: .directoryBookmark)
            case let .external(description):
                try container.encode(SourceType.external, forKey: .type)
                try container.encode(description, forKey: .description)
            }
        }
    }

    let id: UUID
    var title: String
    var author: String?
    var description: String?
    var coverAsset: CollectionCover
    var createdAt: Date
    var updatedAt: Date
    var source: Source
    var tracks: [AudiobookTrack]
    var lastPlayedTrackId: UUID?
    var playbackStates: [UUID: TrackPlaybackState]
    var tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case description
        case coverAsset
        case createdAt
        case updatedAt
        case source
        case tracks
        case lastPlayedTrackId
        case playbackStates
        case legacyLastPlaybackPosition = "lastPlaybackPosition"
        case tags
    }

    init(
        id: UUID,
        title: String,
        author: String?,
        description: String?,
        coverAsset: CollectionCover,
        createdAt: Date,
        updatedAt: Date,
        source: Source,
        tracks: [AudiobookTrack],
        lastPlayedTrackId: UUID?,
        playbackStates: [UUID: TrackPlaybackState],
        tags: [String]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.coverAsset = coverAsset
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.tracks = tracks
        self.lastPlayedTrackId = lastPlayedTrackId
        self.playbackStates = playbackStates
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        coverAsset = try container.decode(CollectionCover.self, forKey: .coverAsset)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decode(Source.self, forKey: .source)
        tracks = try container.decode([AudiobookTrack].self, forKey: .tracks)
        lastPlayedTrackId = try container.decodeIfPresent(UUID.self, forKey: .lastPlayedTrackId)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []

        let decodedStates = try container.decodeIfPresent([UUID: TrackPlaybackState].self, forKey: .playbackStates) ?? [:]
        if decodedStates.isEmpty,
           let legacyPosition = try container.decodeIfPresent(TimeInterval.self, forKey: .legacyLastPlaybackPosition),
           let lastId = lastPlayedTrackId {
            playbackStates = [
                lastId: TrackPlaybackState(
                    position: legacyPosition,
                    duration: nil,
                    updatedAt: updatedAt
                )
            ]
        } else {
            playbackStates = decodedStates
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(coverAsset, forKey: .coverAsset)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(lastPlayedTrackId, forKey: .lastPlayedTrackId)
        try container.encode(playbackStates, forKey: .playbackStates)
        try container.encode(tags, forKey: .tags)
    }

    func playbackState(for trackId: UUID) -> TrackPlaybackState? {
        playbackStates[trackId]
    }
}

struct AudiobookTrack: Identifiable, Codable, Equatable {
    enum Location: Codable, Equatable {
        case baidu(fsId: Int64, path: String)
        case local(urlBookmark: Data)
        case external(url: URL)

        private enum CodingKeys: String, CodingKey {
            case type
            case fsId
            case path
            case urlBookmark
            case url
        }

        private enum LocationType: String, Codable {
            case baidu
            case local
            case external
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(LocationType.self, forKey: .type)

            switch type {
            case .baidu:
                let fsId = try container.decode(Int64.self, forKey: .fsId)
                let path = try container.decode(String.self, forKey: .path)
                self = .baidu(fsId: fsId, path: path)
            case .local:
                let bookmark = try container.decode(Data.self, forKey: .urlBookmark)
                self = .local(urlBookmark: bookmark)
            case .external:
                let url = try container.decode(URL.self, forKey: .url)
                self = .external(url: url)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .baidu(fsId, path):
                try container.encode(LocationType.baidu, forKey: .type)
                try container.encode(fsId, forKey: .fsId)
                try container.encode(path, forKey: .path)
            case let .local(urlBookmark):
                try container.encode(LocationType.local, forKey: .type)
                try container.encode(urlBookmark, forKey: .urlBookmark)
            case let .external(url):
                try container.encode(LocationType.external, forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }
    }

    let id: UUID
    var displayName: String
    var filename: String
    var location: Location
    var fileSize: Int64
    var duration: TimeInterval?
    var trackNumber: Int
    var checksum: String?
    var metadata: [String: String]
}

struct CollectionCover: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case solid(colorHex: String)
        case image(relativePath: String)
        case remote(url: URL)

        private enum CodingKeys: String, CodingKey {
            case type
            case colorHex
            case relativePath
            case url
        }

        private enum KindType: String, Codable {
            case solid
            case image
            case remote
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(KindType.self, forKey: .type)

            switch type {
            case .solid:
                let colorHex = try container.decode(String.self, forKey: .colorHex)
                self = .solid(colorHex: colorHex)
            case .image:
                let path = try container.decode(String.self, forKey: .relativePath)
                self = .image(relativePath: path)
            case .remote:
                let url = try container.decode(URL.self, forKey: .url)
                self = .remote(url: url)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .solid(colorHex):
                try container.encode(KindType.solid, forKey: .type)
                try container.encode(colorHex, forKey: .colorHex)
            case let .image(relativePath):
                try container.encode(KindType.image, forKey: .type)
                try container.encode(relativePath, forKey: .relativePath)
            case let .remote(url):
                try container.encode(KindType.remote, forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }
    }

    var kind: Kind
    var dominantColorHex: String?
}

extension AudiobookCollection {
    static func makeEmptyDraft(for source: Source, title: String) -> AudiobookCollection {
        AudiobookCollection(
            id: UUID(),
            title: title,
            author: nil,
            description: nil,
            coverAsset: CollectionCover(kind: .solid(colorHex: "#5B8DEF"), dominantColorHex: nil),
            createdAt: Date(),
            updatedAt: Date(),
            source: source,
            tracks: [],
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: []
        )
    }
}
