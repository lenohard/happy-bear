import Foundation

final class AudioCacheManager {
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheSizeBytes: Int = 2 * 1024 * 1024 * 1024 // 2GB
    private let minCacheSizeBytes: Int = 1500 * 1024 * 1024 // 1.5GB (cleanup trigger)
    private let defaults = UserDefaults.standard
    private let retentionDefaultsKey = "AudioCacheRetainedDays"
    private let defaultCacheTTLDays: Int = 10
    private var cacheTTLDays: Int

    struct CacheMetadata: Codable {
        struct ByteRange: Codable, Equatable {
            var start: Int
            var end: Int
        }

        enum CacheStatus: String, Codable {
            case partial
            case complete
        }

        let baiduFileId: String
        let trackId: String
        var durationMs: Int?
        var fileSizeBytes: Int?
        var cachedRanges: [ByteRange]
        let createdAt: Date
        var lastAccessedAt: Date
        var cacheStatus: CacheStatus
    }

    init() {
        let cachePaths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let baseCache = cachePaths.first?.appendingPathComponent("AudiobookPlayer/audio-cache") ?? URL(fileURLWithPath: "/tmp/audio-cache")
        self.cacheDirectory = baseCache

        let storedTTL = defaults.integer(forKey: retentionDefaultsKey)
        self.cacheTTLDays = storedTTL > 0 ? storedTTL : defaultCacheTTLDays

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)

        Task {
            self.cleanupExpiredCache()
        }
    }

    func getCachedAssetURL(for trackId: String, baiduFileId: String) -> URL? {
        let cachedURL = cacheFilePath(trackId: trackId, baiduFileId: baiduFileId)

        guard fileManager.fileExists(atPath: cachedURL.path) else {
            return nil
        }

        do {
            var metadata = try loadMetadata(for: trackId, baiduFileId: baiduFileId)
            metadata.lastAccessedAt = Date()
            try saveMetadata(metadata)
            return cachedURL
        } catch {
            print("Failed to update cache metadata: \(error)")
            return cachedURL
        }
    }

    func isCached(trackId: String, baiduFileId: String) -> Bool {
        let cachedURL = cacheFilePath(trackId: trackId, baiduFileId: baiduFileId)
        return fileManager.fileExists(atPath: cachedURL.path)
    }

    func createCacheFile(trackId: String, baiduFileId: String, durationMs: Int? = nil, fileSizeBytes: Int? = nil) -> URL {
        let cachedURL = cacheFilePath(trackId: trackId, baiduFileId: baiduFileId)
        fileManager.createFile(atPath: cachedURL.path, contents: nil, attributes: nil)

        let metadata = CacheMetadata(
            baiduFileId: baiduFileId,
            trackId: trackId,
            durationMs: durationMs,
            fileSizeBytes: fileSizeBytes,
            cachedRanges: [],
            createdAt: Date(),
            lastAccessedAt: Date(),
            cacheStatus: .partial
        )

        do {
            try saveMetadata(metadata)
        } catch {
            print("Failed to save cache metadata: \(error)")
        }

        return cachedURL
    }

    func updateCacheMetadata(trackId: String, baiduFileId: String, durationMs: Int? = nil, fileSizeBytes: Int? = nil) {
        do {
            var metadata = try loadMetadata(for: trackId, baiduFileId: baiduFileId)
            if let durationMs = durationMs {
                metadata.durationMs = durationMs
            }
            if let fileSizeBytes = fileSizeBytes {
                metadata.fileSizeBytes = fileSizeBytes
            }
            metadata.lastAccessedAt = Date()
            try saveMetadata(metadata)
        } catch {
            print("Failed to update cache metadata: \(error)")
        }
    }

    func markCacheAsComplete(trackId: String, baiduFileId: String) {
        do {
            var metadata = try loadMetadata(for: trackId, baiduFileId: baiduFileId)
            metadata.cacheStatus = .complete
            metadata.lastAccessedAt = Date()
            if let fileSizeBytes = metadata.fileSizeBytes {
                metadata.cachedRanges = [CacheMetadata.ByteRange(start: 0, end: fileSizeBytes)]
            }
            try saveMetadata(metadata)
        } catch {
            print("Failed to mark cache as complete: \(error)")
        }
    }

    func removeCacheFile(trackId: String, baiduFileId: String) {
        let fileURL = cacheFilePath(trackId: trackId, baiduFileId: baiduFileId)
        let metadataURL = metadataFilePath(trackId: trackId, baiduFileId: baiduFileId)

        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    func cleanupExpiredCache() {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(cacheTTLDays * 24 * 3600))

        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        for file in files {
            guard file.pathExtension != "json" else { continue }

            do {
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                if let createdDate = attributes[.creationDate] as? Date, createdDate < cutoffDate {
                    try fileManager.removeItem(at: file)
                    let metadataName = file.deletingPathExtension().lastPathComponent + ".json"
                    let metadataURL = cacheDirectory.appendingPathComponent(metadataName)
                    try? fileManager.removeItem(at: metadataURL)
                }
            } catch {
                print("Failed to cleanup cache file \(file.lastPathComponent): \(error)")
            }
        }

        cleanupBySizeIfNeeded()
    }

    private func cleanupBySizeIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        var totalSize: Int = 0
        var fileInfos: [(url: URL, size: Int, accessDate: Date)] = []

        for file in files {
            guard file.pathExtension != "json" else { continue }

            do {
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                let size = attributes[FileAttributeKey.size] as? Int ?? 0
                let accessDate = attributes[FileAttributeKey.modificationDate] as? Date ?? Date()
                totalSize += size
                fileInfos.append((url: file, size: size, accessDate: accessDate))
            } catch {
                print("Failed to get file attributes: \(error)")
            }
        }

        guard totalSize > maxCacheSizeBytes else { return }

        fileInfos.sort { $0.accessDate < $1.accessDate }

        var currentSize = totalSize
        for fileInfo in fileInfos {
            guard currentSize > minCacheSizeBytes else { break }

            do {
                try fileManager.removeItem(at: fileInfo.url)
                let metadataName = fileInfo.url.deletingPathExtension().lastPathComponent + ".json"
                let metadataURL = cacheDirectory.appendingPathComponent(metadataName)
                try? fileManager.removeItem(at: metadataURL)
                currentSize -= fileInfo.size
            } catch {
                print("Failed to remove LRU cache file: \(error)")
            }
        }
    }

    func clearAllCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    func getCacheSize() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return 0
        }

        return files.reduce(0) { total, file in
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let size = attributes?[.size] as? Int ?? 0
            return total + size
        }
    }

    private func cacheFilePath(trackId: String, baiduFileId: String) -> URL {
        let filename = "\(baiduFileId)_\(trackId).cache"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func metadataFilePath(trackId: String, baiduFileId: String) -> URL {
        let filename = "\(baiduFileId)_\(trackId).json"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func saveMetadata(_ metadata: CacheMetadata) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let url = metadataFilePath(trackId: metadata.trackId, baiduFileId: metadata.baiduFileId)
        try data.write(to: url)
    }

    private func loadMetadata(for trackId: String, baiduFileId: String) throws -> CacheMetadata {
        let url = metadataFilePath(trackId: trackId, baiduFileId: baiduFileId)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CacheMetadata.self, from: data)
    }

    func metadata(for trackId: String, baiduFileId: String) -> CacheMetadata? {
        do {
            return try loadMetadata(for: trackId, baiduFileId: baiduFileId)
        } catch {
            return nil
        }
    }

    func updateCachedRanges(
        trackId: String,
        baiduFileId: String,
        ranges: [CacheMetadata.ByteRange],
        cacheStatus: CacheMetadata.CacheStatus
    ) {
        do {
            var metadata = try loadMetadata(for: trackId, baiduFileId: baiduFileId)
            metadata.cachedRanges = ranges
            metadata.cacheStatus = cacheStatus
            metadata.lastAccessedAt = Date()
            try saveMetadata(metadata)
        } catch {
            print("Failed to update cached ranges: \(error)")
        }
    }

    func updateCacheRetention(days: Int) {
        cacheTTLDays = max(1, days)
        defaults.set(cacheTTLDays, forKey: retentionDefaultsKey)
    }

    func currentCacheRetentionDays() -> Int {
        cacheTTLDays
    }

    func cacheDirectoryPath() -> String {
        cacheDirectory.path
    }
}
