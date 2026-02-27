import Foundation

struct TrackPlaybackState: Codable, Equatable {
    var position: TimeInterval
    var duration: TimeInterval?
    var updatedAt: Date
}

struct CollectionFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var coverAsset: CollectionCover? // Optional, if nil, UI should generate a composite or use a default icon

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(), coverAsset: CollectionCover? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverAsset = coverAsset
    }
}

struct AudiobookCollection: Identifiable, Codable, Equatable {
    enum Source: Codable, Equatable {
        case baiduNetdisk(folderPath: String, tokenScope: String)
        case local(directoryBookmark: Data)
        case external(description: String)
        case ephemeralBaidu(path: String)
        case ebook(importedDate: Date, urlBookmark: Data?)
        case rss(feedUrl: URL)

        private enum CodingKeys: String, CodingKey {
            case type
            case folderPath
            case tokenScope
            case directoryBookmark
            case description
            case ephemeralPath
            case importedDate
            case ebookUrlBookmark
            case feedUrl
        }

        private enum SourceType: String, Codable {
            case baiduNetdisk
            case local
            case external
            case ephemeralBaidu
            case ebook
            case rss
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
            case .ephemeralBaidu:
                let path = try container.decode(String.self, forKey: .ephemeralPath)
                self = .ephemeralBaidu(path: path)
            case .ebook:
                let date = try container.decode(Date.self, forKey: .importedDate)
                let bookmark = try container.decodeIfPresent(Data.self, forKey: .ebookUrlBookmark)
                self = .ebook(importedDate: date, urlBookmark: bookmark)
            case .rss:
                let feedUrl = try container.decode(URL.self, forKey: .feedUrl)
                self = .rss(feedUrl: feedUrl)
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
            case let .ephemeralBaidu(path):
                try container.encode(SourceType.ephemeralBaidu, forKey: .type)
                try container.encode(path, forKey: .ephemeralPath)
            case let .ebook(importedDate, urlBookmark):
                try container.encode(SourceType.ebook, forKey: .type)
                try container.encode(importedDate, forKey: .importedDate)
                try container.encodeIfPresent(urlBookmark, forKey: .ebookUrlBookmark)
            case let .rss(feedUrl):
                try container.encode(SourceType.rss, forKey: .type)
                try container.encode(feedUrl, forKey: .feedUrl)
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
    var trackCount: Int
    var shuffleEnabled: Bool
    var isMusic: Bool
    var preferredSortOrder: String?
    var folderId: UUID?
    var isArchived: Bool
    var autoUpdateEnabled: Bool
    var lastRSSCheckDate: Date?

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
        case trackCount
        case shuffleEnabled
        case isMusic
        case preferredSortOrder
        case folderId
        case isArchived
        case autoUpdateEnabled
        case lastRSSCheckDate
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
        tags: [String],
        trackCount: Int? = nil, // Optional for backward compatibility in init, defaults to tracks.count
        shuffleEnabled: Bool = false,
        isMusic: Bool = false,
        preferredSortOrder: String? = nil,
        folderId: UUID? = nil,
        isArchived: Bool = false,
        autoUpdateEnabled: Bool = true,
        lastRSSCheckDate: Date? = nil
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
        self.trackCount = trackCount ?? tracks.count
        self.shuffleEnabled = shuffleEnabled
        self.isMusic = isMusic
        self.preferredSortOrder = preferredSortOrder
        self.folderId = folderId
        self.isArchived = isArchived
        self.autoUpdateEnabled = autoUpdateEnabled
        self.lastRSSCheckDate = lastRSSCheckDate
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

        // For backward compatibility, if trackCount is missing, use tracks.count
        if let count = try container.decodeIfPresent(Int.self, forKey: .trackCount) {
            trackCount = count
        } else {
            trackCount = tracks.count
        }

        shuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
        isMusic = try container.decodeIfPresent(Bool.self, forKey: .isMusic) ?? false
        preferredSortOrder = try container.decodeIfPresent(String.self, forKey: .preferredSortOrder)
        folderId = try container.decodeIfPresent(UUID.self, forKey: .folderId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        autoUpdateEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        lastRSSCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastRSSCheckDate)

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
        try container.encode(trackCount, forKey: .trackCount)
        try container.encode(shuffleEnabled, forKey: .shuffleEnabled)
        try container.encode(isMusic, forKey: .isMusic)
        try container.encodeIfPresent(preferredSortOrder, forKey: .preferredSortOrder)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(autoUpdateEnabled, forKey: .autoUpdateEnabled)
        try container.encodeIfPresent(lastRSSCheckDate, forKey: .lastRSSCheckDate)
    }
    func playbackState(for trackId: UUID) -> TrackPlaybackState? {
        playbackStates[trackId]
    }

    func withShuffleEnabled(_ enabled: Bool) -> AudiobookCollection {
        var copy = self
        copy.shuffleEnabled = enabled
        copy.updatedAt = Date()
        return copy
    }
}

struct AudiobookTrack: Identifiable, Codable, Equatable {
    enum Location: Codable, Equatable {
        case baidu(fsId: Int64, path: String)
        case local(urlBookmark: Data)
        case external(url: URL)
        case text(content: String)
        case cachedText(filename: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case fsId
            case path
            case urlBookmark
            case url
            case content
            case filename
        }

        private enum LocationType: String, Codable {
            case baidu
            case local
            case external
            case text
            case cachedText
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
            case .text:
                let content = try container.decode(String.self, forKey: .content)
                self = .text(content: content)
            case .cachedText:
                let filename = try container.decode(String.self, forKey: .filename)
                self = .cachedText(filename: filename)
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
            case let .text(content):
                try container.encode(LocationType.text, forKey: .type)
                try container.encode(content, forKey: .content)
            case let .cachedText(filename):
                try container.encode(LocationType.cachedText, forKey: .type)
                try container.encode(filename, forKey: .filename)
            }
        }
    }

    enum MediaKind: String, Codable {
        case audio
        case video
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
    var mediaKind: MediaKind = .audio
    
    // NEW: Favorite properties
    var isFavorite: Bool = false
    var favoritedAt: Date?
    
    // NEW: Character count for text tracks
    var characterCount: Int?
    
    // NEW: Chapter support - the parent folder name if tracks are organized into chapters
    var chapter: String?
    
    var isTextTrack: Bool {
        if case .text = location { return true }
        if case .cachedText = location { return true }
        return false
    }
    
    var isVideoTrack: Bool {
        mediaKind == .video
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, displayName, filename, location, fileSize, duration, trackNumber, checksum, metadata
        case mediaKind
        case isFavorite, favoritedAt
        case characterCount
        case chapter
    }
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

extension CollectionCover {
    static func generatedCover(for title: String) -> CollectionCover {
        let hex = colorHex(for: title)
        return CollectionCover(kind: .solid(colorHex: hex), dominantColorHex: hex)
    }

    private static func colorHex(for title: String) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = normalized.isEmpty ? "happybear" : normalized.lowercased()
        let hashValue = abs(seed.hashValue)
        let hue = Double(hashValue % 360) / 360.0
        let saturation = 0.62
        let brightness = 0.85
        let rgb = hsbToRGB(h: hue, s: saturation, v: brightness)
        return String(format: "#%02X%02X%02X", Int(rgb.r * 255), Int(rgb.g * 255), Int(rgb.b * 255))
    }

    private static func hsbToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 0 else { return (v, v, v) }

        let scaledHue = (h * 6).truncatingRemainder(dividingBy: 6)
        let i = Int(floor(scaledHue))
        let f = scaledHue - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))

        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

extension AudiobookCollection {
    static func makeEmptyDraft(for source: Source, title: String) -> AudiobookCollection {
        let defaultCover = CollectionCover.generatedCover(for: title)
        return AudiobookCollection(
            id: UUID(),
            title: title,
            author: nil,
            description: nil,
            coverAsset: defaultCover,
            createdAt: Date(),
            updatedAt: Date(),
            source: source,
            tracks: [],
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: [],
            trackCount: 0,
            shuffleEnabled: false,
            isMusic: false,
            folderId: nil,
            isArchived: false
        )
    }
}

extension TimeInterval {
    var formattedTimestamp: String {
        guard isFinite else { return "--:--" }

        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension AudiobookCollection {
    var isEphemeral: Bool {
        if case .ephemeralBaidu = source {
            return true
        }
        return false
    }
    
    /// Returns tracks sorted by the user's preferred sort order stored in preferredSortOrder
    /// Falls back to filename sorting if no preferred sort order is set
    var tracksSortedByPreferredOrder: [AudiobookTrack] {
        guard let sortOrder = preferredSortOrder else {
            // No preferred sort order - apply smart defaults
            if case .rss = source {
                // RSS collections default to ascending track number (matching display default)
                return tracks.sorted { track1, track2 in
                    if track1.trackNumber != track2.trackNumber {
                        return track1.trackNumber < track2.trackNumber
                    }
                    return track1.displayName.localizedStandardCompare(track2.displayName) == .orderedAscending
                }
            } else {
                // Other collections default to filename sorting
                return tracksSortedByFilename
            }
        }
        
        // Parse "criterion:order" format
        let components = sortOrder.split(separator: ":")
        guard components.count == 2,
              let criterion = SortCriterion(rawValue: String(components[0])),
              let order = SortOrder(rawValue: String(components[1])) else {
            // Invalid format, fallback to filename
            return tracksSortedByFilename
        }
        
        let isAscending = order == .ascending
        
        return tracks.sorted { (track1: AudiobookTrack, track2: AudiobookTrack) in
            let result: Bool
            switch criterion {
            case .trackNumber:
                // Sort by track number (parsed from filename or use display order)
                let num1 = extractTrackNumber(from: track1.filename) ?? 0
                let num2 = extractTrackNumber(from: track2.filename) ?? 0
                result = num1 < num2
            case .title:
                result = track1.displayName.localizedCaseInsensitiveCompare(track2.displayName) == .orderedAscending
            case .pubDate:
                let date1 = Self.parsePubDate(from: track1.metadata["pubDate"])
                let date2 = Self.parsePubDate(from: track2.metadata["pubDate"])
                // If both dates are nil, fall back to filename sort
                guard let d1 = date1, let d2 = date2 else {
                    return track1.filename.localizedCaseInsensitiveCompare(track2.filename) == .orderedAscending
                }
                result = d1 < d2
            }
            
            return isAscending ? result : !result
        }
    }
    
    /// Parse pubDate from metadata string (matching CollectionDetailViewModel)
    private static func parsePubDate(from string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }
    
    /// Extract track number from filename (e.g., "01 - Title.mp3" -> 1)
    private func extractTrackNumber(from filename: String) -> Int? {
        // Try to extract number from beginning of filename
        let pattern = #"^(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        return Int(filename[range])
    }
    
    /// Sort criteria matching CollectionDetailViewModel
    enum SortCriterion: String, CaseIterable {
        case trackNumber = "Track Number"
        case title = "Title"
        case pubDate = "Pub Date"
    }
    
    /// Sort order matching CollectionDetailViewModel
    enum SortOrder: String, CaseIterable {
        case ascending = "Ascending"
        case descending = "Descending"
    }

    var tracksSortedByFilename: [AudiobookTrack] {
        tracks.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
    }
    
    var containsVideoTracks: Bool {
        tracks.contains { $0.mediaKind == .video }
    }

    func resumeTrack() -> AudiobookTrack? {
        let sorted = tracksSortedByFilename

        if let lastPlayedTrackId,
           let match = sorted.first(where: { $0.id == lastPlayedTrackId }) {
            return match
        }

        return sorted.first
    }
    
    var totalCharacterCount: Int? {
        let count = tracks.reduce(0) { $0 + ($1.characterCount ?? 0) }
        return count > 0 ? count : nil
    }
}
