import Foundation

// MARK: - Transcription Manager Retry & Backoff Extension

/// Extension to TranscriptionManager adding retry logic and exponential backoff
extension TranscriptionManager {

    // MARK: - Retry Configuration

    enum RetryConfig {
        static let maxRetries = 3
        static let initialBackoffSeconds: TimeInterval = 5
        static let maxBackoffSeconds: TimeInterval = 300  // 5 minutes max
        static let backoffMultiplier: Double = 3  // 5s → 15s → 45s
    }

    // MARK: - Public Retry API

    /// Retry a failed transcription job by re-running the standard pipeline
    /// - Parameter jobId: The ID of the job to retry
    func retryFailedJob(jobId: String) async throws {
        try await restartJob(jobId: jobId, applyBackoff: true)
    }

    /// Resume a paused/interrupted job (used on manual resume or cold start)
    func resumeTranscriptionJob(jobId: String) async throws {
        try await restartJob(jobId: jobId, applyBackoff: false)
    }

    /// Resume all active jobs on app startup
    @MainActor
    func resumeAllActiveJobs() async {
        do {
            let activeJobs = try await dbManager.loadActiveTranscriptionJobs()

            guard !activeJobs.isEmpty else {
                print("✅ No active transcription jobs to resume")
                return
            }

            print("🚀 Resuming \(activeJobs.count) active transcription job(s)")

            for job in activeJobs {
                if job.isRunning {
                    do {
                        try await resumeTranscriptionJob(jobId: job.id)
                    } catch {
                        print("⚠️ Failed to resume job \(job.id): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("❌ Error resuming active jobs: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    /// Restart a job by rehydrating the track, re-downloading the audio if needed,
    /// and running the normal transcribeTrack flow with the existing job ID.
    private func restartJob(jobId: String, applyBackoff: Bool) async throws {
        guard let job = try await dbManager.loadTranscriptionJob(jobId: jobId) else {
            throw TranscriptionError.trackNotFound
        }

        if applyBackoff {
            guard job.retryCount < RetryConfig.maxRetries else {
                throw TranscriptionError.transcriptionFailed("Maximum retries exceeded")
            }

            let delay = calculateBackoffDelay(retryCount: job.retryCount)
            print("🔄 Scheduling retry for job \(jobId) after \(String(format: "%.1f", delay))s (attempt \(job.retryCount + 1)/\(RetryConfig.maxRetries))")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        guard let trackUUID = UUID(uuidString: job.trackId),
              let (track, collectionId) = try await dbManager.loadTrack(id: trackUUID) else {
            throw TranscriptionError.trackNotFound
        }

        upsertActiveJob(job)

        try await dbManager.resetJobForRetry(jobId: jobId)
        updateActiveJob(jobId: jobId) { current in
            return current.updating(status: "downloading", progress: 0.02, lastAttemptAt: Date())
        }

        do {
            let audioURL = try await resolveAudioForRetry(track: track, jobId: jobId)

            try await transcribeTrack(
                trackId: track.id,
                collectionId: collectionId,
                audioFileURL: audioURL,
                languageHints: ["zh", "en"],
                context: nil,
                existingJobId: jobId
            )
        } catch {
            print("⚠️ Retry for job \(jobId) failed: \(error.localizedDescription)")
            try? await dbManager.markJobFailed(jobId: jobId, errorMessage: error.localizedDescription)
            removeActiveJob(jobId: jobId)
            throw error
        }
    }

    /// Calculate exponential backoff delay in seconds
    private func calculateBackoffDelay(retryCount: Int) -> TimeInterval {
        let baseDelay = RetryConfig.initialBackoffSeconds
        let exponentialDelay = baseDelay * pow(RetryConfig.backoffMultiplier, Double(retryCount))
        let cappedDelay = min(exponentialDelay, RetryConfig.maxBackoffSeconds)
        let jitter = Double.random(in: 0.9...1.1)
        return cappedDelay * jitter
    }

    private func resolveAudioForRetry(track: AudiobookTrack, jobId: String) async throws -> URL {
        switch track.location {
        case let .baidu(fsId, path):
            let cacheManager = AudioCacheManager()
            if let cachedURL = cacheManager.getCachedAssetURL(
                for: track.id.uuidString,
                baiduFileId: String(fsId),
                filename: track.filename
            ) {
                print("[TranscriptionRetry] Cache hit for track \(track.id) fsId=\(fsId)")
                return cachedURL
            }

            let tokenStore: BaiduOAuthTokenStore = KeychainBaiduOAuthTokenStore()
            guard let token = try tokenStore.loadToken() else {
                throw TranscriptionError.missingBaiduToken
            }

            let netdisk = BaiduNetdiskClient()
            let downloadURL = try netdisk.downloadURL(forPath: path, token: token)
            let baiduFileId = String(fsId)
            let downloadManager = AudioCacheDownloadManager(cacheManager: cacheManager)
            print("[TranscriptionRetry] Cache miss for track \(track.id) fsId=\(fsId); downloading")
            let downloaded = try await downloadManager.downloadOnce(
                trackId: track.id.uuidString,
                baiduFileId: baiduFileId,
                filename: track.filename,
                streamingURL: downloadURL,
                cacheSizeBytes: Int(track.fileSize)
            ) { progress in
                let received = Int64(progress.downloadedRange.end)
                let total = Int64(progress.totalBytes)
                Task { await self.updateDownloadProgress(jobId: jobId, receivedBytes: received, totalBytes: total) }
            }

            cacheManager.markCacheAsComplete(trackId: track.id.uuidString, baiduFileId: baiduFileId)
            print("[TranscriptionRetry] Cache download complete for track \(track.id) fsId=\(fsId)")
            return downloaded
        case let .local(bookmark):
            return try resolveLocalBookmark(bookmark)

        case let .external(url):
            if url.isFileURL {
                return url
            }
            return try await downloadFileForRetry(
                from: url,
                jobId: jobId,
                suggestedFilename: track.id.uuidString + "_retry_remote_" + track.filename,
                fallbackTotalBytes: track.fileSize
            ).0
        }
    }

    private func downloadFileForRetry(
        from url: URL,
        destinationURL: URL? = nil,
        jobId: String,
        suggestedFilename: String,
        fallbackTotalBytes: Int64
    ) async throws -> (URL, Int64) {
        let tempFile: URL
        if let destinationURL {
            tempFile = destinationURL
            try? FileManager.default.removeItem(at: tempFile)
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            tempFile = tempDir.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: tempFile)
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: tempFile)
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let resolvedTotal = response.expectedContentLength > 0 ? response.expectedContentLength : (fallbackTotalBytes > 0 ? fallbackTotalBytes : 0)

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var lastReported: Int64 = 0
        var lastReportTime = Date()

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            let delta = received - lastReported
            let timeDelta = Date().timeIntervalSince(lastReportTime)
            if delta >= 64 * 1024 || timeDelta >= 0.2 {
                lastReported = received
                lastReportTime = Date()
                let totalForProgress = resolvedTotal > 0 ? resolvedTotal : max(fallbackTotalBytes, received)
                await updateDownloadProgress(jobId: jobId, receivedBytes: totalForProgress > 0 ? received : 0, totalBytes: totalForProgress)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        if received != lastReported {
            let totalForProgress = resolvedTotal > 0 ? resolvedTotal : max(fallbackTotalBytes, received)
            await updateDownloadProgress(jobId: jobId, receivedBytes: totalForProgress > 0 ? received : 0, totalBytes: totalForProgress)
        }

        return (tempFile, resolvedTotal)
    }

    private func resolveLocalBookmark(_ bookmark: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            throw TranscriptionError.invalidAudioFile
        }

        return url
    }
}
