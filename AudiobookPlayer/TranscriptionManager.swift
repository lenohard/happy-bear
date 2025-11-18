import Foundation

// MARK: - Transcription Manager

/// Manages transcription operations: uploading files, polling status, storing results
@MainActor
class TranscriptionManager: NSObject, ObservableObject {
    enum TranscriptionError: LocalizedError {
        case noAPIKey
        case databaseError(String)
        case transcriptionFailed(String)
        case trackNotFound
        case fileNotFound
        case invalidAudioFile
        case missingBaiduToken
        case pollingTimeout
        case segmentingFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Soniox API key not configured. Add SONIOX_API_KEY to Info.plist"
            case .databaseError(let msg):
                return "Database error: \(msg)"
            case .transcriptionFailed(let msg):
                return "Transcription failed: \(msg)"
            case .trackNotFound:
                return "Track not found in database"
            case .fileNotFound:
                return "Audio file not found"
            case .invalidAudioFile:
                return "Invalid or unsupported audio file"
            case .missingBaiduToken:
                return "Sign in to Baidu before transcribing this track"
            case .pollingTimeout:
                return "Transcription polling timeout"
            case .segmentingFailed:
                return "Failed to segment transcript"
            }
        }
    }

    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0.0
    @Published var currentTrackId: String?
    @Published var errorMessage: String?
    @Published var activeJobs: [TranscriptionJob] = []
    @Published var allRecentJobs: [TranscriptionJob] = []

    var sonioxAPI: SonioxAPI?
    let dbManager: GRDBDatabaseManager
    private let keychainStore: SonioxAPIKeyStore
    let pollingInterval: TimeInterval = 2.0  // Poll every 2 seconds
    let maxPollingDuration: TimeInterval = 3600  // Max 1 hour
    private var pollingTask: Task<Void, Never>?

    init(
        databaseManager: GRDBDatabaseManager = .shared,
        keychainStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore(),
        sonioxAPIKey: String? = nil
    ) {
        self.dbManager = databaseManager
        self.keychainStore = keychainStore

        // Try to load API key in this order:
        // 1. Directly provided (for testing)
        // 2. From Keychain (recommended)
        // 3. From Info.plist (legacy fallback)
        let apiKey = sonioxAPIKey ?? {
            do {
                if let keyFromKeychain = try keychainStore.loadKey() {
                    return keyFromKeychain
                }
            } catch {
                print("Failed to load Soniox key from Keychain: \(error.localizedDescription)")
            }

            // Fallback to Info.plist for backward compatibility
            guard let bundle = Bundle.main.infoDictionary,
                  let key = bundle["SONIOX_API_KEY"] as? String,
                  !key.isEmpty else {
                return nil
            }
            return key
        }()

        if let key = apiKey {
            self.sonioxAPI = SonioxAPI(apiKey: key)
        } else {
            self.sonioxAPI = nil
        }

        super.init()

        Task {
            await refreshActiveJobsFromDatabase()
        }
    }

    // MARK: - API Key Management

    /// Reload the Soniox API key from Keychain
    /// Call this after saving a new API key in the TTS tab
    func reloadSonioxAPIKey() {
        do {
            if let keyFromKeychain = try keychainStore.loadKey() {
                print("[TranscriptionManager] Reloading Soniox API key from Keychain")
                self.sonioxAPI = SonioxAPI(apiKey: keyFromKeychain)
            } else {
                print("[TranscriptionManager] No Soniox API key found in Keychain")
                self.sonioxAPI = nil
            }
        } catch {
            print("[TranscriptionManager] Failed to reload Soniox key from Keychain: \(error.localizedDescription)")
            self.sonioxAPI = nil
        }
    }

    // MARK: - Public API

    /// Transcribe a single audio track
    /// - Parameters:
    ///   - trackId: UUID of the track to transcribe
    ///   - collectionId: UUID of the collection (for database storage)
    ///   - audioFileURL: Local or remote URL to the audio file
    ///   - languageHints: Language hints for Soniox (e.g., ["en"], ["zh"])
    ///   - context: Optional context for better accuracy
    /// - Throws: TranscriptionError
    func transcribeTrack(
        trackId: UUID,
        collectionId: UUID,
        audioFileURL: URL,
        languageHints: [String] = ["zh", "en"],
        context: String? = nil,
        existingJobId: String? = nil
    ) async throws {
        // Reload API key in case it was saved after app launch
        reloadSonioxAPIKey()

        guard let sonioxAPI = sonioxAPI else {
            throw TranscriptionError.noAPIKey
        }

        let trackIdStr = trackId.uuidString
        let collectionIdStr = collectionId.uuidString

        DispatchQueue.main.async {
            self.isTranscribing = true
            self.currentTrackId = trackIdStr
            self.transcriptionProgress = 0.0
            self.errorMessage = nil
        }

        var pendingTranscriptId: String?
        var currentJobId: String? = existingJobId

        do {
            // Create or reuse transcript record
            let transcriptId = try await ensurePendingTranscript(
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                language: languageHints.first ?? "en"
            )
            pendingTranscriptId = transcriptId

            // Create placeholder job if one was not registered during download
            if currentJobId == nil {
                let job = try await dbManager.createTranscriptionJob(
                    trackId: trackIdStr,
                    sonioxJobId: "pending-download-\(UUID().uuidString)",
                    status: "downloading",
                    progress: 0.05
                )
                currentJobId = job.id
                upsertActiveJob(job)
                await refreshAllRecentJobs()
            }

            DispatchQueue.main.async { self.transcriptionProgress = 0.1 }

            // Step 1: Upload file to Soniox
            let fileId = try await sonioxAPI.uploadFile(fileURL: audioFileURL)

            if let jobId = currentJobId {
                try await dbManager.updateJobStatus(jobId: jobId, status: "uploading", progress: 0.15)
                updateActiveJob(jobId: jobId) { existing in
                    existing.updating(status: "uploading", progress: 0.15, lastAttemptAt: Date())
                }
            }

            // Cleanup temporary file if needed
            cleanupTemporaryFileIfNeeded(audioFileURL)

            DispatchQueue.main.async { self.transcriptionProgress = 0.2 }

            // Step 2: Create transcription job
            let transcriptionId = try await sonioxAPI.createTranscription(
                fileId: fileId,
                languageHints: languageHints,
                enableSpeakerDiarization: true,
                context: context
            )

            // Update transcript with job ID
            try await updateTranscriptJobId(trackId: trackIdStr, jobId: transcriptionId, status: "processing")
            DispatchQueue.main.async { self.transcriptionProgress = 0.3 }
            if let jobId = currentJobId {
                try await dbManager.updateJobSonioxId(jobId: jobId, sonioxJobId: transcriptionId)
                try await dbManager.updateJobStatus(jobId: jobId, status: "processing", progress: 0.3)
                updateActiveJob(jobId: jobId) { existing in
                    existing.updating(status: "processing", progress: 0.3, sonioxJobId: transcriptionId, lastAttemptAt: Date())
                }
            }

            // Step 3: Poll for completion
            try await pollForCompletion(
                transcriptionId: transcriptionId,
                trackId: trackIdStr,
                transcriptId: transcriptId,
                fileId: fileId,
                sonioxAPI: sonioxAPI,
                jobId: currentJobId
            )

            // Cleanup succeeded
            try? await sonioxAPI.deleteTranscription(transcriptionId: transcriptionId)
            try? await sonioxAPI.deleteFile(fileId: fileId)

            if let jobId = currentJobId {
                try await dbManager.markJobCompleted(jobId: jobId)
                removeActiveJob(jobId: jobId)
            }

            DispatchQueue.main.async {
                self.isTranscribing = false
                self.currentTrackId = nil
                self.transcriptionProgress = 1.0
            }
        } catch {
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.currentTrackId = nil
                self.errorMessage = error.localizedDescription
            }
            if pendingTranscriptId != nil {
                await markTranscriptFailure(trackId: trackIdStr, message: error.localizedDescription)
            }
            if let jobId = currentJobId {
                try? await dbManager.markJobFailed(jobId: jobId, errorMessage: error.localizedDescription)
                removeActiveJob(jobId: jobId)
            }
            throw error
        }
    }

    /// Register a placeholder job so UI can show download state before the Soniox upload begins
    func beginDownloadJob(for trackId: UUID) async -> TranscriptionJob? {
        let trackIdStr = trackId.uuidString

        if let existing = activeJobs.first(where: { $0.trackId == trackIdStr }) {
            return existing
        }

        do {
            let job = try await dbManager.createTranscriptionJob(
                trackId: trackIdStr,
                sonioxJobId: "pending-download-\(UUID().uuidString)",
                status: "downloading",
                progress: 0.02
            )
            upsertActiveJob(job)
            await refreshAllRecentJobs()
            return job
        } catch {
            print("[TranscriptionManager] Failed to create download placeholder: \(error.localizedDescription)")
            return nil
        }
    }

    /// Update placeholder progress while downloading source audio
    func updateDownloadProgress(jobId: String, receivedBytes: Int64, totalBytes: Int64) async {
        guard totalBytes > 0 else { return }
        let fraction = max(0.0, min(Double(receivedBytes) / Double(totalBytes), 1.0))

        do {
            try await dbManager.updateJobStatus(jobId: jobId, status: "downloading", progress: fraction)
            updateActiveJob(jobId: jobId) { current in
                current.updating(status: "downloading", progress: fraction)
            }
        } catch {
            print("[TranscriptionManager] Failed to update download progress: \(error.localizedDescription)")
        }
    }

    /// Retrieve transcript for a track
    /// - Parameter trackId: UUID of the track
    /// - Returns: Transcript if available, nil otherwise
    func getTranscript(trackId: UUID) async throws -> Transcript? {
        do {
            return try await dbManager.loadTranscript(forTrackId: trackId.uuidString)
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    /// Delete transcript for a track
    /// - Parameter trackId: UUID of the track
    func deleteTranscript(forTrackId trackId: UUID) async throws {
        do {
            try await dbManager.deleteTranscript(forTrackId: trackId.uuidString)
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    /// Retrieve all segments for a transcript
    /// - Parameter transcriptId: UUID of the transcript
    /// - Returns: Array of transcript segments
    func getTranscriptSegments(transcriptId: String) async throws -> [TranscriptSegment] {
        do {
            return try await dbManager.loadTranscriptSegments(forTranscriptId: transcriptId)
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    /// Search for text in a transcript
    /// - Parameters:
    ///   - query: Search query string
    ///   - transcriptId: Transcript to search in
    /// - Returns: Array of matching segments with context
    func searchTranscript(query: String, transcriptId: String) async throws -> [TranscriptSearchResult] {
        let segments = try await getTranscriptSegments(transcriptId: transcriptId)
        let lowercaseQuery = query.lowercased()

        return segments.enumerated().compactMap { index, segment in
            let lowerText = segment.text.lowercased()
            guard lowerText.contains(lowercaseQuery) else {
                return nil
            }

            let occurrences = lowerText.components(separatedBy: lowercaseQuery).count - 1
            return TranscriptSearchResult(
                segmentIndex: index,
                segment: segment,
                matchCount: max(1, occurrences),
                matchedText: highlightMatch(in: segment.text, query: query)
            )
        }
    }

    // MARK: - Private Helpers

    private func updateTranscriptJobId(trackId: String, jobId: String, status: String) async throws {
        do {
            try await dbManager.updateTranscriptJobMetadata(trackId: trackId, jobId: jobId, status: status)
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    private func pollForCompletion(
        transcriptionId: String,
        trackId: String,
        transcriptId: String,
        fileId: String,
        sonioxAPI: SonioxAPI,
        jobId: String?
    ) async throws {
        let startTime = Date()
        var pollCount = 0

        while Date().timeIntervalSince(startTime) < maxPollingDuration {
            pollCount += 1

            do {
                let status = try await sonioxAPI.checkTranscriptionStatus(transcriptionId: transcriptionId)

                if status.status == "completed" {
                    // Get transcript and save segments
                    let transcript = try await sonioxAPI.getTranscript(transcriptionId: transcriptionId)
                    try await saveTranscriptData(
                        transcript: transcript,
                        trackId: trackId,
                        transcriptId: transcriptId
                    )

                    DispatchQueue.main.async {
                        self.transcriptionProgress = 1.0
                    }

                    if let jobId {
                        try await dbManager.updateJobStatus(jobId: jobId, status: "completed", progress: 1.0)
                    }
                    return
                } else if status.status == "error" {
                    if let jobId {
                        try await dbManager.markJobFailed(jobId: jobId, errorMessage: status.error_message ?? "Unknown error")
                        removeActiveJob(jobId: jobId)
                    }
                    throw TranscriptionError.transcriptionFailed(status.error_message ?? "Unknown error")
                } else if status.status == "processing" || status.status == "queued" {
                    // Update progress (simple linear estimate)
                    let elapsed = Date().timeIntervalSince(startTime)
                    let estimatedProgress = 0.3 + (elapsed / maxPollingDuration) * 0.6
                    DispatchQueue.main.async {
                        self.transcriptionProgress = min(estimatedProgress, 0.9)
                    }

                    if let jobId {
                        let normalizedProgress = min(estimatedProgress, 0.9)
                        try await dbManager.updateJobStatus(jobId: jobId, status: status.status, progress: normalizedProgress)
                        updateActiveJob(jobId: jobId) { job in
                            job.updating(status: status.status, progress: normalizedProgress, lastAttemptAt: Date())
                        }
                    }
                }

                // Wait before next poll
                try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            } catch let error as SonioxAPI.APIError {
                throw TranscriptionError.transcriptionFailed(error.localizedDescription)
            }
        }

        throw TranscriptionError.pollingTimeout
    }

    private func saveTranscriptData(
        transcript: SonioxTranscriptResponse,
        trackId: String,
        transcriptId: String
    ) async throws {
        // Group tokens into segments (by speaker or time gap)
        let segments = groupTokensIntoSegments(transcript.tokens, transcriptId: transcriptId)

        // Build full text
        let fullText = segments.map { $0.text }.joined(separator: " ")

        do {
            try await dbManager.saveTranscriptSegments(segments, for: transcriptId)
            try await dbManager.finalizeTranscript(trackId: trackId, fullText: fullText)
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    private func groupTokensIntoSegments(_ tokens: [SonioxToken], transcriptId: String) -> [TranscriptSegment] {
        let maxSegmentDurationMs = 20_000  // Hard cap of 20 seconds per segment
        let preferredBreakCharacters: Set<Character> = [",", "，", ".", "。", "!", "！", "?", "？", ";", "；", "、"]

        struct SegmentToken {
            let text: String
            let startMs: Int
            let endMs: Int
            let confidence: Double?
        }

        struct PartialSegment {
            var tokens: [SegmentToken]
            var speaker: String?
            var language: String?
        }

        var segments: [TranscriptSegment] = []
        var currentSegment: PartialSegment? = nil

        func averageConfidence(for tokens: [SegmentToken]) -> Double? {
            let confidences = tokens.compactMap { $0.confidence }
            guard !confidences.isEmpty else { return nil }
            let total = confidences.reduce(0, +)
            return total / Double(confidences.count)
        }

        func appendSegment(from tokens: [SegmentToken], speaker: String?, language: String?) {
            guard let first = tokens.first, let last = tokens.last else { return }
            let fullText = combineTokens(tokens.map { $0.text }, languageCode: language)
            let confidence = averageConfidence(for: tokens)
            let segment = TranscriptSegment(
                transcriptId: transcriptId,
                text: fullText,
                startTimeMs: first.startMs,
                endTimeMs: last.endMs,
                confidence: confidence,
                speaker: speaker,
                language: language
            )
            segments.append(segment)
        }

        func finalizeCurrentSegment() {
            guard let current = currentSegment else { return }
            appendSegment(from: current.tokens, speaker: current.speaker, language: current.language)
            currentSegment = nil
        }

        func splitCurrentSegment(at index: Int) {
            guard var current = currentSegment, !current.tokens.isEmpty else { return }
            let clampedIndex = max(0, min(index, current.tokens.count - 1))
            let leadingTokens = Array(current.tokens[...clampedIndex])
            appendSegment(from: leadingTokens, speaker: current.speaker, language: current.language)

            let trailingStart = clampedIndex + 1
            if trailingStart < current.tokens.count {
                current.tokens = Array(current.tokens[trailingStart...])
                currentSegment = current
            } else {
                currentSegment = nil
            }
        }

        func startNewSegment(with token: SegmentToken, speaker: String?, language: String?) {
            currentSegment = PartialSegment(tokens: [token], speaker: speaker, language: language)
        }

        func appendToken(_ token: SegmentToken) {
            guard var current = currentSegment else { return }
            current.tokens.append(token)
            currentSegment = current
        }

        func exceedsDurationLimit(with newEndMs: Int) -> Bool {
            guard let start = currentSegment?.tokens.first?.startMs else { return false }
            return (newEndMs - start) >= maxSegmentDurationMs
        }

        func endsWithSentencePunctuation(_ text: String) -> Bool {
            let sentenceEnders: Set<Character> = [".", "。", "!", "！", "?", "？"]
            return sentenceEnders.contains(text.last ?? " ")
        }

        func lastPreferredBreakIndex() -> Int? {
            guard let tokens = currentSegment?.tokens, !tokens.isEmpty else { return nil }
            guard let start = tokens.first?.startMs else { return nil }

            for (index, token) in tokens.enumerated().reversed() {
                guard token.text.contains(where: { preferredBreakCharacters.contains($0) }) else { continue }
                if (token.endMs - start) <= maxSegmentDurationMs {
                    return index
                }
            }
            return nil
        }

        for token in tokens {
            let startMs = token.start_ms ?? 0
            let endMs = token.end_ms ?? startMs
            let text = token.text
            let speaker = token.speaker ?? "unknown"
            let language = token.language
            let segmentToken = SegmentToken(text: text, startMs: startMs, endMs: endMs, confidence: token.confidence)

            if currentSegment == nil {
                startNewSegment(with: segmentToken, speaker: speaker, language: language)
                continue
            }

            let currentSpeaker = currentSegment?.speaker ?? "unknown"
            let speakerChanged = currentSpeaker != speaker

            if speakerChanged {
                finalizeCurrentSegment()
                startNewSegment(with: segmentToken, speaker: speaker, language: language)
                continue
            }

            if var updated = currentSegment, updated.language == nil, let language {
                updated.language = language
                currentSegment = updated
            }

            if exceedsDurationLimit(with: endMs) {
                if let breakIndex = lastPreferredBreakIndex() {
                    splitCurrentSegment(at: breakIndex)
                    if currentSegment == nil {
                        startNewSegment(with: segmentToken, speaker: speaker, language: language)
                    } else if exceedsDurationLimit(with: endMs) {
                        finalizeCurrentSegment()
                        startNewSegment(with: segmentToken, speaker: speaker, language: language)
                    } else {
                        appendToken(segmentToken)
                        if endsWithSentencePunctuation(text) {
                            finalizeCurrentSegment()
                        }
                    }
                } else {
                    finalizeCurrentSegment()
                    startNewSegment(with: segmentToken, speaker: speaker, language: language)
                }
                continue
            }

            appendToken(segmentToken)
            if endsWithSentencePunctuation(text) {
                finalizeCurrentSegment()
            }
        }

        finalizeCurrentSegment()

        return segments
    }

    private func combineTokens(_ tokens: [String], languageCode: String?) -> String {
        guard shouldInsertSpaces(for: languageCode) else {
            return tokens.joined()
        }

        var combined = tokens.joined(separator: " ")

        let punctuation = [".", ",", "!", "?", ";", ":", ")", "]", "}", "，", "。", "！", "？", "；", "："]
        for symbol in punctuation {
            combined = combined.replacingOccurrences(of: " \(symbol)", with: symbol)
        }

        while combined.contains("  ") {
            combined = combined.replacingOccurrences(of: "  ", with: " ")
        }

        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldInsertSpaces(for languageCode: String?) -> Bool {
        guard let languageCode else { return true }
        let trimmed = languageCode.lowercased()
        let languagesWithoutSpaces = ["zh", "ja", "ko"]
        return !languagesWithoutSpaces.contains { trimmed.hasPrefix($0) }
    }

    private func ensurePendingTranscript(
        trackId: String,
        collectionId: String,
        language: String
    ) async throws -> String {
        do {
            if let existing = try await dbManager.loadTranscript(forTrackId: trackId) {
                return existing.id
            }

            let transcriptId = UUID().uuidString
            try await dbManager.saveTranscript(
                id: transcriptId,
                trackId: trackId,
                collectionId: collectionId,
                language: language,
                fullText: "",
                jobStatus: "pending",
                jobId: nil
            )
            return transcriptId
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    private func markTranscriptFailure(trackId: String, message: String) async {
        do {
            try await dbManager.markTranscriptFailed(trackId: trackId, message: message)
        } catch {
            print("Failed to mark transcript failure: \(error.localizedDescription)")
        }
    }

    private func cleanupTemporaryFileIfNeeded(_ url: URL) {
        let tempDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let fileURL = url.standardizedFileURL

        guard fileURL.path.hasPrefix(tempDirectory.path) else { return }

        try? FileManager.default.removeItem(at: fileURL)
    }

    private func refreshActiveJobsFromDatabase() async {
        do {
            let jobs = try await dbManager.loadActiveTranscriptionJobs()
            await MainActor.run {
                self.activeJobs = jobs
            }
        } catch {
            print("[TranscriptionManager] Failed to refresh active jobs: \(error.localizedDescription)")
        }
    }

    /// Refresh all recent jobs from database (public method for UI to call)
    func refreshAllRecentJobs() async {
        do {
            let jobs = try await dbManager.loadAllRecentTranscriptionJobs(limit: 50)
            await MainActor.run {
                self.allRecentJobs = jobs
            }
        } catch {
            print("[TranscriptionManager] Failed to refresh all jobs: \(error.localizedDescription)")
        }
    }

    /// Pause a running job (local state only)
    func pauseJob(jobId: String) async throws {
        guard let job = try await dbManager.loadTranscriptionJob(jobId: jobId) else {
            throw TranscriptionError.trackNotFound
        }

        try await dbManager.updateJobStatus(jobId: jobId, status: "paused", progress: job.progress)
        updateActiveJob(jobId: jobId) { current in
            current.updating(status: "paused", lastAttemptAt: Date())
        }
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    /// Resume a paused job by re-polling Soniox
    func resumeJob(jobId: String) async throws {
        try await resumeTranscriptionJob(jobId: jobId)
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    /// Retry a failed job with exponential backoff
    func retryJob(jobId: String) async throws {
        try await retryFailedJob(jobId: jobId)
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    /// Delete a job record
    func deleteJob(jobId: String) async throws {
        try await dbManager.deleteTranscriptionJob(jobId: jobId)
        removeActiveJob(jobId: jobId)
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    /// Reload both active and recent jobs after a full import/restore event.
    func reloadJobsAfterImport() async {
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    func upsertActiveJob(_ job: TranscriptionJob) {
        if let index = activeJobs.firstIndex(where: { $0.id == job.id }) {
            activeJobs[index] = job
        } else {
            activeJobs.append(job)
        }
    }

    func updateActiveJob(jobId: String, transform: (TranscriptionJob) -> TranscriptionJob) {
        if let index = activeJobs.firstIndex(where: { $0.id == jobId }) {
            activeJobs[index] = transform(activeJobs[index])
        }
    }

    func removeActiveJob(jobId: String) {
        activeJobs.removeAll { $0.id == jobId }
    }

    private func highlightMatch(in text: String, query: String) -> String {
        // Simple highlight - could be enhanced with regex
        let caseInsensitiveRange = text.range(
            of: query,
            options: .caseInsensitive
        )

        if let range = caseInsensitiveRange {
            var result = text
            result.replaceSubrange(range, with: "**\(String(text[range]))**")
            return result
        }

        return text
    }
}
