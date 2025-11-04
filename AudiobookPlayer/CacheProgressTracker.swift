import Foundation

@MainActor
final class CacheProgressTracker: ObservableObject {
    @Published private(set) var cachedRanges: [String: [AudioCacheManager.CacheMetadata.ByteRange]] = [:]
    @Published private(set) var downloadProgress: [String: Double] = [:]

    private let cacheManager: AudioCacheManager
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(cacheManager: AudioCacheManager) {
        self.cacheManager = cacheManager
    }

    func getCachedPercentage(for trackId: String, fileSizeBytes: Int?) -> Double {
        guard let ranges = cachedRanges[trackId], !ranges.isEmpty else { return 0 }
        guard let fileSize = fileSizeBytes, fileSize > 0 else { return 0 }

        let totalCached = ranges.reduce(0) { sum, range in
            sum + max(0, range.end - range.start)
        }

        return min(1.0, Double(totalCached) / Double(fileSize))
    }

    func isCached(trackId: String, position: Int, duration: Int) -> Bool {
        guard let ranges = cachedRanges[trackId] else { return false }

        return ranges.contains { range in
            position >= range.start && position <= range.end
        }
    }

    func progress(for trackId: String) -> Double {
        downloadProgress[trackId] ?? 0
    }

    func updateProgress(
        for trackId: String,
        downloadedRange: AudioCacheManager.CacheMetadata.ByteRange,
        totalBytes: Int
    ) {
        let progress = totalBytes > 0 ? Double(downloadedRange.end) / Double(totalBytes) : 0
        downloadProgress[trackId] = min(1.0, progress)

        var ranges = cachedRanges[trackId] ?? []
        ranges.append(downloadedRange)
        cachedRanges[trackId] = mergeOverlappingRanges(ranges)
    }

    func clearProgress(for trackId: String) {
        downloadProgress.removeValue(forKey: trackId)
        cachedRanges.removeValue(forKey: trackId)
        downloadTasks[trackId]?.cancel()
        downloadTasks.removeValue(forKey: trackId)
    }

    func markAsComplete(for trackId: String, fileSizeBytes: Int) {
        cachedRanges[trackId] = [AudioCacheManager.CacheMetadata.ByteRange(start: 0, end: fileSizeBytes)]
        downloadProgress[trackId] = 1.0
    }

    func resetAll() {
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks.removeAll()
        downloadProgress.removeAll()
        cachedRanges.removeAll()
    }

    func startTracking(
        for trackId: String,
        baiduFileId: String,
        with downloadManager: AudioCacheDownloadManager,
        duration: Int
    ) {
        downloadTasks[trackId]?.cancel()

        downloadTasks[trackId] = Task {
            while !Task.isCancelled {
                if let metadata = cacheManager.metadata(for: trackId, baiduFileId: baiduFileId) {
                    await MainActor.run { [weak self] in
                        self?.cachedRanges[trackId] = metadata.cachedRanges
                        if metadata.cacheStatus == .complete {
                            self?.downloadProgress[trackId] = 1.0
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopTracking(for trackId: String) {
        downloadTasks[trackId]?.cancel()
        downloadTasks.removeValue(forKey: trackId)
    }

    private func mergeOverlappingRanges(
        _ ranges: [AudioCacheManager.CacheMetadata.ByteRange]
    ) -> [AudioCacheManager.CacheMetadata.ByteRange] {
        guard !ranges.isEmpty else { return [] }

        let sortedRanges = ranges.sorted { $0.start < $1.start }
        var merged: [AudioCacheManager.CacheMetadata.ByteRange] = []

        for range in sortedRanges {
            if var last = merged.last, last.end >= range.start {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }

        return merged
    }
}
