import Foundation

final class AudioCacheDownloadManager {
    struct DownloadProgress {
        let trackId: String
        let downloadedRange: AudioCacheManager.CacheMetadata.ByteRange
        let totalBytes: Int
    }

    typealias ProgressCallback = (DownloadProgress) -> Void

    private var activeDownloads: [String: URLSessionDataTask] = [:]
    private let session: URLSession
    private let cacheManager: AudioCacheManager

    init(cacheManager: AudioCacheManager) {
        self.cacheManager = cacheManager

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.networkServiceType = .responsiveData

        self.session = URLSession(configuration: config)
    }

    func startCaching(
        trackId: String,
        baiduFileId: String,
        streamingURL: URL,
        cacheSizeBytes: Int,
        progressCallback: @escaping ProgressCallback
    ) async {
        if activeDownloads[trackId] != nil {
            return
        }

        let cacheURL = cacheManager.createCacheFile(
            trackId: trackId,
            baiduFileId: baiduFileId,
            fileSizeBytes: cacheSizeBytes
        )

        let task = downloadAudio(
            from: streamingURL,
            to: cacheURL,
            trackId: trackId,
            baiduFileId: baiduFileId,
            totalBytes: cacheSizeBytes,
            progressCallback: progressCallback
        )

        activeDownloads[trackId] = task
        task.resume()
    }

    func cancelCaching(for trackId: String) {
        activeDownloads[trackId]?.cancel()
        activeDownloads.removeValue(forKey: trackId)
    }

    func pauseCaching(for trackId: String) {
        activeDownloads[trackId]?.suspend()
    }

    func resumeCaching(for trackId: String) {
        activeDownloads[trackId]?.resume()
    }

    private func downloadAudio(
        from url: URL,
        to destinationURL: URL,
        trackId: String,
        baiduFileId: String,
        totalBytes: Int,
        progressCallback: @escaping ProgressCallback
    ) -> URLSessionDataTask {
        let request = URLRequest(url: url)

        let task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
            Task {
                await self?.handleDownloadResponse(
                    tempURL: tempURL,
                    response: response,
                    error: error,
                    destinationURL: destinationURL,
                    trackId: trackId,
                    baiduFileId: baiduFileId,
                    totalBytes: totalBytes,
                    progressCallback: progressCallback
                )
            }
        }

        return task
    }

    private func handleDownloadResponse(
        tempURL: URL?,
        response: URLResponse?,
        error: Error?,
        destinationURL: URL,
        trackId: String,
        baiduFileId: String,
        totalBytes: Int,
        progressCallback: @escaping ProgressCallback
    ) async {
        defer {
            activeDownloads.removeValue(forKey: trackId)
        }

        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                print("Download error for track \(trackId): \(error.localizedDescription)")
            }
            return
        }

        guard let tempURL = tempURL else {
            print("No temp URL for downloaded track \(trackId)")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            let fileSize = try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int ?? totalBytes
            let range = AudioCacheManager.CacheMetadata.ByteRange(start: 0, end: fileSize)

            cacheManager.updateCacheMetadata(trackId: trackId, baiduFileId: baiduFileId, fileSizeBytes: fileSize)
            cacheManager.updateCachedRanges(
                trackId: trackId,
                baiduFileId: baiduFileId,
                ranges: [range],
                cacheStatus: .complete
            )

            Task { @MainActor in
                progressCallback(DownloadProgress(trackId: trackId, downloadedRange: range, totalBytes: fileSize))
            }
        } catch {
            print("Failed to write cache file for track \(trackId): \(error.localizedDescription)")
        }
    }

    deinit {
        activeDownloads.values.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }
}
