import Foundation

final class AudioCacheDownloadManager {
    struct DownloadProgress {
        let trackId: String
        let downloadedRange: AudioCacheManager.CacheMetadata.ByteRange
        let totalBytes: Int
    }

    typealias ProgressCallback = (DownloadProgress) -> Void

    private var activeDownloads: [String: URLSessionTask] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private var completions: [String: (Result<URL, Error>) -> Void] = [:]
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
        filename: String,
        streamingURL: URL,
        cacheSizeBytes: Int,
        progressCallback: @escaping ProgressCallback,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) async {
        if activeDownloads[trackId] != nil {
            return
        }

        let cacheURL = cacheManager.createCacheFile(
            trackId: trackId,
            baiduFileId: baiduFileId,
            filename: filename,
            fileSizeBytes: cacheSizeBytes
        )

        let task = downloadAudio(
            from: streamingURL,
            to: cacheURL,
            trackId: trackId,
            baiduFileId: baiduFileId,
            totalBytes: cacheSizeBytes,
            progressCallback: progressCallback,
            completion: completion
        )

        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            guard cacheSizeBytes > 0 else { return }
            let clamped = max(0.0, min(1.0, progress.fractionCompleted))
            let bytes = Int((Double(cacheSizeBytes) * clamped).rounded())
            let range = AudioCacheManager.CacheMetadata.ByteRange(start: 0, end: bytes)
            Task { @MainActor in
                progressCallback(DownloadProgress(trackId: trackId, downloadedRange: range, totalBytes: cacheSizeBytes))
            }
        }

        progressObservers[trackId] = observation
        activeDownloads[trackId] = task
        if let completion { completions[trackId] = completion }
        task.resume()
    }

    func cancelCaching(for trackId: String) {
        activeDownloads[trackId]?.cancel()
        activeDownloads.removeValue(forKey: trackId)
        progressObservers[trackId]?.invalidate()
        progressObservers.removeValue(forKey: trackId)
        completions.removeValue(forKey: trackId)
    }

    func isDownloading(trackId: String) -> Bool {
        activeDownloads[trackId] != nil
    }

    func pauseCaching(for trackId: String) {
        activeDownloads[trackId]?.suspend()
    }

    func resumeCaching(for trackId: String) {
        activeDownloads[trackId]?.resume()
    }

    func cancelAll() {
        activeDownloads.values.forEach { $0.cancel() }
        activeDownloads.removeAll()
        progressObservers.values.forEach { $0.invalidate() }
        progressObservers.removeAll()
        completions.removeAll()
    }

    private func downloadAudio(
        from url: URL,
        to destinationURL: URL,
        trackId: String,
        baiduFileId: String,
        totalBytes: Int,
        progressCallback: @escaping ProgressCallback,
        completion: ((Result<URL, Error>) -> Void)?
    ) -> URLSessionDownloadTask {
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
                    progressCallback: progressCallback,
                    completion: completion
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
        progressCallback: @escaping ProgressCallback,
        completion: ((Result<URL, Error>) -> Void)?
    ) async {
        defer {
            activeDownloads.removeValue(forKey: trackId)
            progressObservers[trackId]?.invalidate()
            progressObservers.removeValue(forKey: trackId)
            completions.removeValue(forKey: trackId)
        }

        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                print("Download error for track \(trackId): \(error.localizedDescription)")
            }
            completion?(.failure(error))
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

            completion?(.success(destinationURL))
        } catch {
            print("Failed to write cache file for track \(trackId): \(error.localizedDescription)")
            completion?(.failure(error))
        }
    }

    /// Convenience async helper for one-shot downloads with completion when the
    /// file is fully written to cache.
    func downloadOnce(
        trackId: String,
        baiduFileId: String,
        filename: String,
        streamingURL: URL,
        cacheSizeBytes: Int,
        progressCallback: @escaping ProgressCallback
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await startCaching(
                    trackId: trackId,
                    baiduFileId: baiduFileId,
                    filename: filename,
                    streamingURL: streamingURL,
                    cacheSizeBytes: cacheSizeBytes,
                    progressCallback: progressCallback,
                    completion: { result in
                        continuation.resume(with: result)
                    }
                )
            }
        }
    }

    deinit {
        activeDownloads.values.forEach { $0.cancel() }
        session.invalidateAndCancel()
        progressObservers.values.forEach { $0.invalidate() }
    }
}
