import Foundation

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
    var lastPlaybackPosition: TimeInterval?
    var tags: [String]
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
            lastPlaybackPosition: nil,
            tags: []
        )
    }
}
