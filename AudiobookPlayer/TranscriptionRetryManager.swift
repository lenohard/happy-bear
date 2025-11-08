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

    /// Retry a failed transcription job with exponential backoff
    /// - Parameter jobId: The ID of the job to retry
    func retryFailedJob(jobId: String) async throws {
        guard let job = try await dbManager.loadTranscriptionJob(jobId: jobId) else {
            throw TranscriptionError.trackNotFound
        }

        // Check if we can retry
        guard job.retryCount < RetryConfig.maxRetries else {
            throw TranscriptionError.transcriptionFailed("Maximum retries exceeded")
        }

        // Calculate exponential backoff
        let backoffSeconds = calculateBackoffDelay(retryCount: job.retryCount)

        print("🔄 Scheduling retry for job \(jobId) after \(backoffSeconds)s (attempt \(job.retryCount + 1)/\(RetryConfig.maxRetries))")

        // Wait before retrying
        try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

        // Reset job and retry
        try await dbManager.resetJobForRetry(jobId: jobId)
        try await resumeTranscriptionJob(jobId: jobId)
    }

    /// Resume a paused or interrupted transcription job
    /// Useful for app restart scenarios
    func resumeTranscriptionJob(jobId: String) async throws {
        guard let job = try await dbManager.loadTranscriptionJob(jobId: jobId) else {
            throw TranscriptionError.trackNotFound
        }

        print("▶️ Resuming transcription job \(jobId) (status: \(job.status))")

        // Update status to show we're resuming
        try await dbManager.updateJobStatus(jobId: jobId, status: "transcribing")

        // Poll for completion
        try await pollTranscriptionStatus(sonioxJobId: job.sonioxJobId, jobId: jobId)
    }

    /// Resume all active jobs on app startup
    /// Call this from app initialization
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
                // Only resume jobs that were in-progress
                if job.isRunning {
                    do {
                        try await resumeTranscriptionJob(jobId: job.id)
                    } catch {
                        print("⚠️ Failed to resume job \(job.id): \(error.localizedDescription)")
                        // Continue with next job
                    }
                }
            }
        } catch {
            print("❌ Error resuming active jobs: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    /// Calculate exponential backoff delay in seconds
    private func calculateBackoffDelay(retryCount: Int) -> TimeInterval {
        let baseDelay = RetryConfig.initialBackoffSeconds
        let exponentialDelay = baseDelay * pow(RetryConfig.backoffMultiplier, Double(retryCount))
        let cappedDelay = min(exponentialDelay, RetryConfig.maxBackoffSeconds)

        // Add jitter (±10%) to prevent thundering herd
        let jitter = Double.random(in: 0.9...1.1)
        return cappedDelay * jitter
    }

    /// Poll Soniox for job completion with retry handling
    private func pollTranscriptionStatus(
        sonioxJobId: String,
        jobId: String
    ) async throws {
        guard let sonioxAPI = self.sonioxAPI else {
            throw TranscriptionError.noAPIKey
        }

        let startTime = Date()
        let maxDuration = maxPollingDuration

        while Date().timeIntervalSince(startTime) < maxDuration {
            do {
                // Check status
                let status = try await sonioxAPI.checkAsyncRecognitionStatus(jobId: sonioxJobId)

                // Update progress
                try await dbManager.updateJobProgress(jobId: jobId, progress: status.progress ?? 0.5)

                switch status.state {
                case "completed", "done":
                    // Get final result
                    let result = try await sonioxAPI.getAsyncRecognitionResult(jobId: sonioxJobId)
                    try await handleTranscriptionComplete(jobId: jobId, result: result)
                    return

                case "failed", "error":
                    // Handle failure with retry
                    let errorMsg = status.errorDescription ?? "Transcription failed"
                    try await dbManager.markJobFailed(jobId: jobId, errorMessage: errorMsg)
                    throw TranscriptionError.transcriptionFailed(errorMsg)

                default:
                    // Still processing, continue polling
                    print("📊 Job \(jobId) progress: \(Int((status.progress ?? 0.5) * 100))%")
                    try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                }

            } catch {
                // API error - potentially retryable
                print("⚠️ Poll error for job \(jobId): \(error.localizedDescription)")

                // Mark as failed for potential retry
                try await dbManager.markJobFailed(jobId: jobId, errorMessage: error.localizedDescription)

                // Re-throw to let caller handle retry
                throw error
            }
        }

        // Timeout
        let timeoutError = TranscriptionError.pollingTimeout
        try await dbManager.markJobFailed(jobId: jobId, errorMessage: timeoutError.localizedDescription ?? "Polling timeout")
        throw timeoutError
    }

    /// Handle successful transcription completion
    private func handleTranscriptionComplete(
        jobId: String,
        result: SonioxRecognitionResult
    ) async throws {
        // Mark job as completed
        try await dbManager.markJobCompleted(jobId: jobId)

        // Store transcript and segments
        try await storeTranscriptResult(result: result, jobId: jobId)

        print("✅ Transcription job \(jobId) completed successfully")
    }

    /// Store transcription result in database
    private func storeTranscriptResult(
        result: SonioxRecognitionResult,
        jobId: String
    ) async throws {
        // Implementation would store segments and create transcript record
        // This is already handled in the main TranscriptionManager.transcribe() method
        // This is just a placeholder for consistency
    }
}

// MARK: - Soniox API Extensions for Async Status Checking

extension SonioxAPI {

    /// Check status of an async recognition job
    func checkAsyncRecognitionStatus(jobId: String) async throws -> AsyncRecognitionStatus {
        let url = baseURL.appendingPathComponent("GetAsyncRecognition")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let queryItems = [URLQueryItem(name: "jobId", value: jobId)]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems

        guard let finalURL = components?.url else {
            throw NSError(domain: "SonioxAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        request.url = finalURL

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SonioxAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SonioxAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AsyncRecognitionStatus.self, from: data)
    }

    /// Get the final result of a completed async recognition job
    func getAsyncRecognitionResult(jobId: String) async throws -> SonioxRecognitionResult {
        // This would call GetAsyncRecognition and return the result
        // Implementation details depend on Soniox API response format
        throw NSError(domain: "SonioxAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }
}

// MARK: - Models for Async Recognition

struct AsyncRecognitionStatus: Codable {
    let state: String  // "completed", "failed", "processing", etc.
    let progress: Double?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case state
        case progress
        case errorDescription = "error_description"
    }
}

struct SonioxRecognitionResult: Codable {
    let jobId: String
    let transcription: String
    let segments: [SonioxSegment]?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case transcription
        case segments
        case language
    }
}

struct SonioxSegment: Codable {
    let text: String
    let startTimeMs: Int
    let endTimeMs: Int
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case startTimeMs = "start_time_ms"
        case endTimeMs = "end_time_ms"
        case confidence
    }
}
