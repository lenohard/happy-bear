import Foundation
import OSLog
import AVFoundation

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
        case remoteJobsUnavailable

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
            case .remoteJobsUnavailable:
                return "Remote jobs are not configured."
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
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "TranscriptionManager")
    private var downloadProgressMilestones: [String: Double] = [:]
    private let remoteJobPrefix = "remote:"
    private var remotePollingJobs: Set<String> = []

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
                AppLog.debug("Failed to load Soniox key from Keychain: \(error.localizedDescription)")
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
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TranscriptionJobUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                if let jobId = notification.userInfo?["jobId"] as? String {
                    await self?.refreshJob(jobId)
                } else {
                    await self?.refreshActiveJobsFromDatabase()
                    await self?.refreshAllRecentJobs()
                }
            }
        }
    }

    // MARK: - API Key Management

    /// Reload the Soniox API key from Keychain
    /// Call this after saving a new API key in the TTS tab
    func reloadSonioxAPIKey() {
        do {
            if let keyFromKeychain = try keychainStore.loadKey() {
                logger.info("[TranscriptionManager] Reloading Soniox API key from Keychain")
                self.sonioxAPI = SonioxAPI(apiKey: keyFromKeychain)
            } else {
                logger.info("[TranscriptionManager] No Soniox API key found in Keychain")
                self.sonioxAPI = nil
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to reload Soniox key from Keychain: \(error.localizedDescription, privacy: .public)")
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

        guard let api = sonioxAPI else {
            throw TranscriptionError.noAPIKey
        }

        let trackIdStr = trackId.uuidString
        let collectionIdStr = collectionId.uuidString
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let fileSizeBytes = (fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0

        logger.info(
            "[TranscriptionManager] Begin transcription for track \(trackIdStr, privacy: .public) collection \(collectionIdStr, privacy: .public) existingJob=\(existingJobId ?? "nil", privacy: .public) file=\(audioFileURL.lastPathComponent, privacy: .public) size=\(fileSizeBytes, privacy: .public)"
        )

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
            let ensuredTranscriptId = try await ensurePendingTranscript(
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                language: languageHints.first ?? "en"
            )
            pendingTranscriptId = ensuredTranscriptId
            logger.debug("[TranscriptionManager] Ensured pending transcript \(ensuredTranscriptId, privacy: .public) for track \(trackIdStr, privacy: .public)")

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
                logger.info("[TranscriptionManager] Created placeholder job \(job.id, privacy: .public) for track \(trackIdStr, privacy: .public)")
            } else if let jobId = currentJobId {
                logger.debug("[TranscriptionManager] Reusing existing job \(jobId, privacy: .public) for track \(trackIdStr, privacy: .public)")
            }
            
            // Check for existing file ID to skip upload
            var fileId: String?
            if let jobId = currentJobId, let job = try await dbManager.loadTranscriptionJob(jobId: jobId) {
                fileId = job.sonioxFileId
                if let existing = fileId {
                    logger.info("[TranscriptionManager] Found existing file ID \(existing, privacy: .public) for job \(jobId, privacy: .public). Skipping upload.")
                }
            }

            DispatchQueue.main.async { self.transcriptionProgress = 0.1 }

            if let jobId = currentJobId {
                // If skipping upload, jump straight to processing/uploading end state
                let status = fileId != nil ? "uploading" : "uploading"
                let progress = fileId != nil ? 0.2 : 0.1
                
                try await dbManager.updateJobStatus(jobId: jobId, status: status, progress: progress)
                updateActiveJob(jobId: jobId) { existing in
                    existing.updating(status: status, progress: progress, lastAttemptAt: Date())
                }
            }
            
            // Step 1: Upload file to Soniox (if not already uploaded)
            if fileId == nil {
                var uploadFileURL = audioFileURL
                var extractedAudioURL: URL?

                // Check if track is video and extract audio if needed
                if let (track, _) = try? await dbManager.loadTrack(id: trackId), track.mediaKind == .video {
                     logger.info("[TranscriptionManager] Track is video, extracting audio...")
                     
                     if let jobId = currentJobId {
                         try await dbManager.updateJobStatus(jobId: jobId, status: "extracting", progress: 0.1)
                         updateActiveJob(jobId: jobId) { existing in
                            existing.updating(status: "extracting", progress: 0.1, lastAttemptAt: Date())
                         }
                     }
                     
                     extractedAudioURL = try await extractAudioFromVideo(videoURL: audioFileURL)
                     uploadFileURL = extractedAudioURL!
                     logger.info("[TranscriptionManager] Audio extracted to \(uploadFileURL.path)")
                     
                     // Update status back to uploading
                     if let jobId = currentJobId {
                         try await dbManager.updateJobStatus(jobId: jobId, status: "uploading", progress: 0.15)
                         updateActiveJob(jobId: jobId) { existing in
                            existing.updating(status: "uploading", progress: 0.15, lastAttemptAt: Date())
                         }
                     }
                }

                let newFileId = try await api.uploadFile(fileURL: uploadFileURL)
                logger.info("[TranscriptionManager] Upload complete for track \(trackIdStr, privacy: .public); fileId=\(newFileId, privacy: .public) size=\(fileSizeBytes, privacy: .public)")
                
                // Save file ID for potential retries
                if let jobId = currentJobId {
                    try await dbManager.updateJobSonioxFileId(jobId: jobId, sonioxFileId: newFileId)
                    // Update local object immediately to reflect the change if needed
                    updateActiveJob(jobId: jobId) { existing in
                        existing.updating(sonioxFileId: newFileId)
                    }
                }
                
                fileId = newFileId

                if let jobId = currentJobId {
                    try await dbManager.updateJobStatus(jobId: jobId, status: "uploading", progress: 0.2)
                    updateActiveJob(jobId: jobId) { existing in
                        existing.updating(status: "uploading", progress: 0.2, lastAttemptAt: Date())
                    }
                }

                // Cleanup temporary file if needed
                if let extracted = extractedAudioURL {
                    try? FileManager.default.removeItem(at: extracted)
                }
                cleanupTemporaryFileIfNeeded(audioFileURL)
            }
            
            guard let validFileId = fileId else {
                throw TranscriptionError.transcriptionFailed("Failed to resolve file ID")
            }

            DispatchQueue.main.async { self.transcriptionProgress = 0.2 }

            // Step 2: Create transcription job
            let transcriptionId = try await api.createTranscription(
                fileId: validFileId,
                languageHints: languageHints,
                enableSpeakerDiarization: true,
                context: context
            )
            logger.info("[TranscriptionManager] Created Soniox transcription \(transcriptionId, privacy: .public) for track \(trackIdStr, privacy: .public); hints=\(languageHints.joined(separator: ","), privacy: .public) contextLen=\(context?.count ?? 0, privacy: .public)")

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

            logger.info("[TranscriptionManager] Starting poll for Soniox job \(transcriptionId, privacy: .public) (db job \(currentJobId ?? "nil", privacy: .public)) track \(trackIdStr, privacy: .public)")
            // Step 3: Poll for completion
            try await pollForCompletion(
                transcriptionId: transcriptionId,
                trackId: trackIdStr,
                transcriptId: ensuredTranscriptId,
                fileId: validFileId,
                sonioxAPI: api,
                jobId: currentJobId
            )

            // Cleanup succeeded
            try? await api.deleteTranscription(transcriptionId: transcriptionId)
            try? await api.deleteFile(fileId: validFileId)

            if let jobId = currentJobId {
                try await dbManager.markJobCompleted(jobId: jobId)
                removeActiveJob(jobId: jobId)
                downloadProgressMilestones[jobId] = nil
                await refreshAllRecentJobs()
                logger.info("[TranscriptionManager] Job \(jobId, privacy: .public) completed successfully for track \(trackIdStr, privacy: .public)")
            }

            DispatchQueue.main.async {
                self.isTranscribing = false
                self.currentTrackId = nil
                self.transcriptionProgress = 1.0
            }
            logger.info("[TranscriptionManager] Finished transcription for track \(trackIdStr, privacy: .public)")
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
                downloadProgressMilestones[jobId] = nil
                await refreshAllRecentJobs()
                logger.error("[TranscriptionManager] Job \(jobId, privacy: .public) failed for track \(trackIdStr, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    func transcribeTrackRemote(
        trackId: UUID,
        collectionId: UUID,
        input: RemoteJobsInput,
        languageHints: [String] = ["zh", "en"],
        context: String? = nil,
        existingJobId: String? = nil
    ) async throws {
        let config = try loadRemoteJobsConfig()
        let client = RemoteJobsClient(config: config)

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
            let ensuredTranscriptId = try await ensurePendingTranscript(
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                language: languageHints.first ?? "en"
            )
            pendingTranscriptId = ensuredTranscriptId

            if currentJobId == nil {
                let job = try await dbManager.createTranscriptionJob(
                    trackId: trackIdStr,
                    sonioxJobId: "\(remoteJobPrefix)pending-\(UUID().uuidString)",
                    status: "transcribing",
                    progress: 0.05
                )
                currentJobId = job.id
                upsertActiveJob(job)
                await refreshAllRecentJobs()
            } else if let jobId = currentJobId, let job = try await dbManager.loadTranscriptionJob(jobId: jobId) {
                upsertActiveJob(job)
            }

            DispatchQueue.main.async { self.transcriptionProgress = 0.15 }

            let remoteJob = try await client.createSTTJob(input: input, languageHints: languageHints, context: context)
            let storedRemoteId = "\(remoteJobPrefix)\(remoteJob.id)"

            if let jobId = currentJobId {
                try await dbManager.updateJobSonioxId(jobId: jobId, sonioxJobId: storedRemoteId)
                try await dbManager.updateJobStatus(jobId: jobId, status: "transcribing", progress: 0.2)
                updateActiveJob(jobId: jobId) { current in
                    current.updating(status: "transcribing", progress: 0.2, lastAttemptAt: Date())
                }
            }

            try await updateTranscriptJobId(trackId: trackIdStr, jobId: storedRemoteId, status: "processing")

            let startTime = Date()
            var latestStatus = remoteJob
            while latestStatus.status == "queued" || latestStatus.status == "running" {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > maxPollingDuration {
                    throw TranscriptionError.pollingTimeout
                }
                try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                latestStatus = try await client.fetchJob(jobId: remoteJob.id)
                let progress = latestStatus.progress ?? 0.4
                DispatchQueue.main.async { self.transcriptionProgress = max(self.transcriptionProgress, progress) }
                if let jobId = currentJobId {
                    try await dbManager.updateJobStatus(jobId: jobId, status: "transcribing", progress: progress)
                    updateActiveJob(jobId: jobId) { current in
                        current.updating(status: "transcribing", progress: progress, lastAttemptAt: Date())
                    }
                }
            }

            guard latestStatus.status == "succeeded" else {
                throw TranscriptionError.transcriptionFailed("Remote job \(latestStatus.status)")
            }

            let result = try await client.fetchSTTResult(jobId: remoteJob.id)
            let srtText = result.srt ?? ""
            let transcriptText = result.transcript ?? ""
            let transcriptId = pendingTranscriptId ?? UUID().uuidString
            let segments = parseSRTSegments(srtText, transcriptId: transcriptId)
            let fullText = transcriptText.isEmpty ? segments.map { $0.text }.joined(separator: "\n") : transcriptText

            let transcript = Transcript(
                id: transcriptId,
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                language: languageHints.first ?? "en",
                fullText: fullText,
                createdAt: Date(),
                updatedAt: Date(),
                jobStatus: "complete",
                jobId: storedRemoteId,
                errorMessage: nil
            )
            try await dbManager.saveTranscript(transcript, segments: segments)
            NotificationCenter.default.post(
                name: .transcriptDidFinalize,
                object: nil,
                userInfo: [
                    "trackId": trackIdStr,
                    "transcriptId": transcriptId
                ]
            )

            if let jobId = currentJobId {
                try await dbManager.markJobCompleted(jobId: jobId)
                updateActiveJob(jobId: jobId) { current in
                    current.updating(status: "completed", progress: 1.0, lastAttemptAt: Date())
                }
                removeActiveJob(jobId: jobId)
            }

            DispatchQueue.main.async {
                self.transcriptionProgress = 1.0
                self.isTranscribing = false
                self.currentTrackId = nil
            }
        } catch {
            if let jobId = currentJobId {
                try? await dbManager.markJobFailed(jobId: jobId, errorMessage: error.localizedDescription)
                removeActiveJob(jobId: jobId)
            }
            if pendingTranscriptId != nil {
                await markTranscriptFailure(trackId: trackIdStr, message: error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.errorMessage = error.localizedDescription
                self.currentTrackId = nil
            }
            throw error
        }
    }

    func enqueueRemoteSTTJob(
        trackId: UUID,
        collectionId: UUID,
        input: RemoteJobsInput,
        languageHints: [String] = ["zh", "en"],
        context: String? = nil,
        existingJobId: String? = nil
    ) async throws -> RemoteJobDTO {
        let config = try loadRemoteJobsConfig()
        let client = RemoteJobsClient(config: config)

        let trackIdStr = trackId.uuidString
        let collectionIdStr = collectionId.uuidString

        _ = try await ensurePendingTranscript(
            trackId: trackIdStr,
            collectionId: collectionIdStr,
            language: languageHints.first ?? "en"
        )

        var currentJobId: String? = existingJobId

        if currentJobId == nil {
            let job = try await dbManager.createTranscriptionJob(
                trackId: trackIdStr,
                sonioxJobId: "\(remoteJobPrefix)pending-\(UUID().uuidString)",
                status: "queued",
                progress: 0.05
            )
            currentJobId = job.id
            upsertActiveJob(job)
            await refreshAllRecentJobs()
        } else if let jobId = currentJobId, let job = try await dbManager.loadTranscriptionJob(jobId: jobId) {
            upsertActiveJob(job)
        }

        let remoteJob = try await client.createSTTJob(input: input, languageHints: languageHints, context: context)
        let storedRemoteId = "\(remoteJobPrefix)\(remoteJob.id)"
        let progress = max(remoteJob.progress ?? 0.1, 0.1)
        let status = remoteJob.status == "queued" ? "queued" : "transcribing"

        if let jobId = currentJobId {
            try await dbManager.updateJobSonioxId(jobId: jobId, sonioxJobId: storedRemoteId)
            try await dbManager.updateJobStatus(jobId: jobId, status: status, progress: progress)
            updateActiveJob(jobId: jobId) { current in
                current.updating(status: status, progress: progress, lastAttemptAt: Date())
            }
        }

        try await updateTranscriptJobId(trackId: trackIdStr, jobId: storedRemoteId, status: "processing")
        await refreshAllRecentJobs()
        if let jobId = currentJobId, let job = try await dbManager.loadTranscriptionJob(jobId: jobId) {
            Task { @MainActor [weak self] in
                await self?.startRemotePollingIfNeeded(job: job)
            }
        }
        return remoteJob
    }

    func resolveRemoteSTTInput(
        track: AudiobookTrack,
        collectionId: UUID,
        baiduToken: BaiduOAuthToken?
    ) async throws -> RemoteJobsInput? {
        switch track.location {
        case let .baidu(_, path):
            guard let token = baiduToken else {
                throw TranscriptionError.missingBaiduToken
            }
            let netdiskClient = BaiduNetdiskClient()
            let downloadURL = try netdiskClient.downloadURL(forPath: path, token: token)
            return RemoteJobsInput(
                url: downloadURL,
                source: "baidu",
                cookie: nil,
                mime: nil
            )
        case let .external(url):
            if url.isFileURL {
                return nil
            }
            let source = try await resolveRemoteSource(for: collectionId)
            return RemoteJobsInput(
                url: url,
                source: source,
                cookie: nil,
                mime: nil
            )
        case .local:
            return nil
        case .text, .cachedText:
            throw TranscriptionError.invalidAudioFile
        }
    }

    /// Register a placeholder job so UI can show download state before the Soniox upload begins
    func beginDownloadJob(for trackId: UUID) async -> TranscriptionJob? {
        let trackIdStr = trackId.uuidString

        if let existing = activeJobs.first(where: { $0.trackId == trackIdStr }) {
            logger.debug("[TranscriptionManager] Reusing existing active job \(existing.id, privacy: .public) for track \(trackIdStr, privacy: .public)")
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
            logger.info("[TranscriptionManager] Created download placeholder job \(job.id, privacy: .public) for track \(trackIdStr, privacy: .public)")
            return job
        } catch {
            logger.error("[TranscriptionManager] Failed to create download placeholder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func beginRemoteJob(for trackId: UUID) async -> TranscriptionJob? {
        let trackIdStr = trackId.uuidString
        if let existing = activeJobs.first(where: { $0.trackId == trackIdStr }) {
            return existing
        }

        do {
            let job = try await dbManager.createTranscriptionJob(
                trackId: trackIdStr,
                sonioxJobId: "\(remoteJobPrefix)pending-\(UUID().uuidString)",
                status: "transcribing",
                progress: 0.05
            )
            upsertActiveJob(job)
            await refreshAllRecentJobs()
            return job
        } catch {
            logger.error("[TranscriptionManager] Failed to create remote job placeholder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Update placeholder progress while downloading source audio
    func updateDownloadProgress(jobId: String, receivedBytes: Int64, totalBytes: Int64) async {
        guard totalBytes > 0 else { return }
        let fraction = max(0.0, min(Double(receivedBytes) / Double(totalBytes), 1.0))
        let previous = downloadProgressMilestones[jobId] ?? -1
        if previous < 0 {
            logger.debug("[TranscriptionManager] Download job \(jobId, privacy: .public) started (totalBytes=\(totalBytes, privacy: .public))")
        }

        do {
            try await dbManager.updateJobStatus(jobId: jobId, status: "downloading", progress: fraction)
            updateActiveJob(jobId: jobId) { current in
                current.updating(status: "downloading", progress: fraction)
            }
            downloadProgressMilestones[jobId] = fraction
            if fraction >= 0.99 && previous < 0.99 {
                logger.info("[TranscriptionManager] Download job \(jobId, privacy: .public) completed (bytes=\(receivedBytes, privacy: .public)/\(totalBytes, privacy: .public))")
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to update download progress: \(error.localizedDescription, privacy: .public)")
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
        var lastStatus: String?

        logger.info("[TranscriptionManager] Polling Soniox job \(transcriptionId, privacy: .public) for track \(trackId, privacy: .public); dbJob=\(jobId ?? "nil", privacy: .public)")

        while Date().timeIntervalSince(startTime) < maxPollingDuration {
            pollCount += 1

            do {
                let status = try await sonioxAPI.checkTranscriptionStatus(transcriptionId: transcriptionId)
                if status.status != lastStatus {
                    logger.info("[TranscriptionManager] Soniox job \(transcriptionId, privacy: .public) status=\(status.status, privacy: .public) poll=\(pollCount)")
                    lastStatus = status.status
                }

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
                    logger.info("[TranscriptionManager] Soniox job \(transcriptionId, privacy: .public) completed for track \(trackId, privacy: .public)")
                    return
                } else if status.status == "error" {
                    logger.error("[TranscriptionManager] Soniox job \(transcriptionId, privacy: .public) errored: \(status.error_message ?? "unknown", privacy: .public)")
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
                logger.error("[TranscriptionManager] Polling failed for \(transcriptionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw TranscriptionError.transcriptionFailed(error.localizedDescription)
            }
        }

        logger.error("[TranscriptionManager] Polling timeout for Soniox job \(transcriptionId, privacy: .public)")
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
            NotificationCenter.default.post(
                name: .transcriptDidFinalize,
                object: nil,
                userInfo: [
                    "trackId": trackId,
                    "transcriptId": transcriptId
                ]
            )
        } catch {
            throw TranscriptionError.databaseError(error.localizedDescription)
        }
    }

    private func groupTokensIntoSegments(_ tokens: [SonioxToken], transcriptId: String) -> [TranscriptSegment] {
        let maxSegmentDurationMs = 20_000  // Hard cap of 20 seconds per segment
        let minSegmentDurationMs = 1_500   // Soft minimum: don't split on punctuation if segment is too short
        let maxSilenceGapMs = 600          // If gap to next token is > 0.6s, allow split (respect silence)
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
            guard let lastChar = text.last, sentenceEnders.contains(lastChar) else {
                return false
            }
            
            // If it ends with non-period punctuation, it's a sentence ender
            if lastChar != "." && lastChar != "。" {
                return true
            }
            
            // For periods, check if it's an abbreviation
            // Common abbreviations that should NOT split segments
            let abbreviations = [
                "mr.", "mrs.", "ms.", "miss.", "dr.", "prof.", "sr.", "jr.",
                "st.", "ave.", "blvd.", "rd.", "ln.", "ct.", "pl.",
                "inc.", "ltd.", "corp.", "co.", "llc.",
                "no.", "vol.", "vs.", "etc.", "al.", "i.e.", "e.g.",
                "ph.d.", "m.d.", "b.a.", "m.a.", "b.s.", "m.s.",
                "a.m.", "p.m.", "u.s.", "u.k.", "u.n."
            ]
            
            let lowercased = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if the entire text is just an abbreviation
            if abbreviations.contains(lowercased) {
                return false
            }
            
            // Check if text ends with an abbreviation (e.g., "said Mrs.")
            for abbr in abbreviations {
                if lowercased.hasSuffix(abbr) {
                    // Make sure it's a word boundary before the abbreviation
                    let prefix = lowercased.dropLast(abbr.count)
                    if prefix.isEmpty || prefix.last?.isWhitespace == true || prefix.last?.isPunctuation == true {
                        return false
                    }
                }
            }
            
            // Not an abbreviation, so it's a sentence ender
            return true
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

        for (index, token) in tokens.enumerated() {
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
            
            var shouldSplit = endsWithSentencePunctuation(text)
            
            // Logic: Protect decimal numbers like "7.5" or "7." followed by "5"
            // Only applies if punctuation is a period
            if shouldSplit && (text == "." || text.hasSuffix(".")) {
                // Look ahead for digit
                if index + 1 < tokens.count {
                    let nextTokenText = tokens[index + 1].text.trimmingCharacters(in: .whitespaces)
                    // Check if next token starts with digit
                    if let firstNext = nextTokenText.first, firstNext.isNumber {
                        // Look behind for digit
                        var isPrecededByNumber = false
                        
                        if text == "." {
                            // Case: ["7", ".", "5"] -> text is "."
                            // Check token before this "."
                            // Since we just appended `segmentToken`, it is the last one in `currentSegment`.
                            // We need the one before it.
                            let count = currentSegment?.tokens.count ?? 0
                            if count >= 2 {
                                let prevTokenText = currentSegment!.tokens[count - 2].text.trimmingCharacters(in: .whitespaces)
                                if let lastPrev = prevTokenText.last, lastPrev.isNumber {
                                    isPrecededByNumber = true
                                }
                            }
                        } else {
                            // Case: ["7.", "5"] -> text is "7."
                            let prefix = text.dropLast()
                            if let lastPrefix = prefix.last, lastPrefix.isNumber {
                                isPrecededByNumber = true
                            }
                        }
                        
                        if isPrecededByNumber {
                            shouldSplit = false
                        }
                    }
                }
            }
            
            // Logic: Min Duration Threshold
            // Don't split if the segment is too short, UNLESS there is a large silence gap.
            if shouldSplit {
                if let start = currentSegment?.tokens.first?.startMs,
                   let end = currentSegment?.tokens.last?.endMs {
                    let duration = end - start
                    
                    var gapToNext = 0
                    if index + 1 < tokens.count {
                        let nextStart = tokens[index + 1].start_ms ?? endMs
                        // Ensure positive gap
                        if nextStart > endMs {
                            gapToNext = nextStart - endMs
                        }
                    }
                    
                    // Only enforce min duration if the gap to the next token is small.
                    // If there's a large silence (e.g. > 600ms), we should respect the split
                    // even if the current segment is short.
                    if duration < minSegmentDurationMs && gapToNext < maxSilenceGapMs {
                        shouldSplit = false
                    }
                }
            }

            if shouldSplit {
                finalizeCurrentSegment()
            }
        }

        finalizeCurrentSegment()

        return segments
    }

    private func combineTokens(_ tokens: [String], languageCode: String?) -> String {
        // Soniox API returns tokens where spacing is already encoded via leading spaces.
        // For example: ["Peng", "u", "in", " Rand", "om", " House"]
        // When joined directly: "Penguin Random House" ✅
        // When joined with spaces: "Peng u in  Rand om  House" ❌
        //
        // Strategy: Just join tokens directly without any separator.
        // The API handles spacing for all languages (English, CJK, etc.)
        
        let combined = tokens.joined()
        
        // Clean up any potential double spaces (defensive)
        var result = combined
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func extractAudioFromVideo(videoURL: URL) async throws -> URL {
        let asset = AVAsset(url: videoURL)
        
        // Create export session
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.transcriptionFailed("Could not create export session")
        }
        
        // Create temporary output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        await exportSession.export()
        
        if let error = exportSession.error {
            throw TranscriptionError.transcriptionFailed("Audio extraction failed: \(error.localizedDescription)")
        }
        
        guard exportSession.status == .completed else {
            throw TranscriptionError.transcriptionFailed("Audio extraction failed with status: \(exportSession.status.rawValue)")
        }
        
        return outputURL
    }

    private func markTranscriptFailure(trackId: String, message: String) async {
        do {
            try await dbManager.markTranscriptFailed(trackId: trackId, message: message)
        } catch {
            AppLog.debug("Failed to mark transcript failure: \(error.localizedDescription)")
        }
    }

    private func cleanupTemporaryFileIfNeeded(_ url: URL) {
        let tempDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let fileURL = url.standardizedFileURL

        guard fileURL.path.hasPrefix(tempDirectory.path) else { return }

        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Refresh active jobs from database (public for UI to call)
    func refreshActiveJobsFromDatabase() async {
        do {
            let jobs = try await dbManager.loadActiveTranscriptionJobs()
            await MainActor.run {
                self.activeJobs = jobs
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to refresh active jobs: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshJob(_ jobId: String) async {
        do {
            if let job = try await dbManager.loadTranscriptionJob(jobId: jobId) {
                await MainActor.run {
                    if job.status == "completed" || job.status == "failed" || job.status == "canceled" {
                        self.removeActiveJob(jobId: jobId)
                    } else {
                        self.upsertActiveJob(job)
                    }
                    
                    if let index = self.allRecentJobs.firstIndex(where: { $0.id == jobId }) {
                        self.allRecentJobs[index] = job
                    }
                }
                
                if job.status == "completed" || job.status == "failed" || job.status == "canceled" {
                    await self.refreshAllRecentJobs()
                }
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to refresh job \(jobId): \(error.localizedDescription, privacy: .public)")
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
            logger.error("[TranscriptionManager] Failed to refresh all jobs: \(error.localizedDescription, privacy: .public)")
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

    /// Check for pending STT jobs that were interrupted when app went to background
    /// and resume them. Called when app becomes active.
    func checkAndResumePendingJobs() async {
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()

        // Find STT jobs (not TTS jobs) that were in a processing state
        // TTS jobs use prefix "tts-", STT jobs use real Soniox IDs or "pending-download-"
        let sttJobs = activeJobs.filter { job in
            !job.sonioxJobId.hasPrefix("tts-") &&
            !job.sonioxJobId.hasPrefix(remoteJobPrefix) &&
            job.status != "paused" &&
            job.status != "completed" &&
            job.status != "failed"
        }

        let remoteJobs = activeJobs.filter { job in
            job.sonioxJobId.hasPrefix(remoteJobPrefix) &&
            job.status != "paused" &&
            job.status != "completed" &&
            job.status != "failed"
        }

        guard !sttJobs.isEmpty || !remoteJobs.isEmpty else {
            logger.debug("[TranscriptionManager] No interrupted STT jobs to resume")
            return
        }

        if !sttJobs.isEmpty {
            logger.info("[TranscriptionManager] Found \(sttJobs.count) interrupted STT job(s) to check")
        }

        for job in sttJobs {
            // Check if job has a valid Soniox job ID (meaning upload completed)
            if !job.sonioxJobId.hasPrefix("pending-download-") {
                // Job has a real Soniox ID - poll for status
                logger.info("[TranscriptionManager] Checking Soniox status for job \(job.id, privacy: .public) sonioxId=\(job.sonioxJobId, privacy: .public)")
                await checkSonioxJobStatus(job: job)
            } else {
                // Job was still in download/upload phase - needs restart
                logger.info("[TranscriptionManager] Job \(job.id, privacy: .public) was interrupted during download - marking as needs resume")
                // Don't auto-restart downloads - let user manually retry
                // Just refresh the UI state
            }
        }

        if !remoteJobs.isEmpty {
            logger.info("[TranscriptionManager] Found \(remoteJobs.count) interrupted remote job(s) to check")
        }

        for job in remoteJobs {
            await startRemotePollingIfNeeded(job: job)
        }

        // Refresh UI after checking
        await refreshActiveJobsFromDatabase()
        await refreshAllRecentJobs()
    }

    private func resumeRemoteJob(job: TranscriptionJob) async {
        guard let remoteJobId = remoteJobId(from: job.sonioxJobId) else {
            logger.error("[TranscriptionManager] Remote job \(job.id, privacy: .public) missing remote ID; skip resume")
            return
        }

        let trackIdStr = job.trackId
        let config: RemoteJobsConfig
        do {
            config = try loadRemoteJobsConfig()
        } catch {
            logger.error("[TranscriptionManager] Remote jobs disabled or invalid config; skip resume for \(job.id, privacy: .public)")
            return
        }

        let client = RemoteJobsClient(config: config)

        do {
            try await updateTranscriptJobId(trackId: trackIdStr, jobId: job.sonioxJobId, status: "processing")
        } catch {
            logger.error("[TranscriptionManager] Failed to update transcript metadata for remote job \(job.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let startTime = Date()
        var latestStatus = try? await client.fetchJob(jobId: remoteJobId)

        while let status = latestStatus, isRemoteJobRunning(status.status) {
            let progress = status.progress ?? 0.4
            await updateRemoteJobProgress(jobId: job.id, status: status.status, progress: progress)

            if Date().timeIntervalSince(startTime) > maxPollingDuration {
                await markRemoteJobFailed(jobId: job.id, trackId: trackIdStr, message: "Remote polling timeout")
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            latestStatus = try? await client.fetchJob(jobId: remoteJobId)
        }

        guard let finalStatus = latestStatus else {
            await markRemoteJobFailed(jobId: job.id, trackId: trackIdStr, message: "Remote job status unavailable")
            return
        }

        if finalStatus.status == "succeeded" {
            await finalizeRemoteJobSuccess(
                jobId: job.id,
                trackId: trackIdStr,
                remoteJobId: remoteJobId,
                client: client
            )
        } else {
            await markRemoteJobFailed(
                jobId: job.id,
                trackId: trackIdStr,
                message: "Remote job \(finalStatus.status)"
            )
        }
    }

    private func startRemotePollingIfNeeded(job: TranscriptionJob) async {
        let inserted = remotePollingJobs.insert(job.id).inserted
        guard inserted else { return }
        defer { remotePollingJobs.remove(job.id) }
        await resumeRemoteJob(job: job)
    }

    private func remoteJobId(from sonioxJobId: String) -> String? {
        guard sonioxJobId.hasPrefix(remoteJobPrefix) else { return nil }
        let rawId = String(sonioxJobId.dropFirst(remoteJobPrefix.count))
        guard !rawId.isEmpty, !rawId.hasPrefix("pending-") else { return nil }
        return rawId
    }

    private func isRemoteJobRunning(_ status: String) -> Bool {
        status == "queued" || status == "running" || status == "processing"
    }

    private func updateRemoteJobProgress(jobId: String, status: String, progress: Double) async {
        let localStatus = status == "queued" ? "queued" : "transcribing"
        do {
            try await dbManager.updateJobStatus(jobId: jobId, status: localStatus, progress: progress)
            updateActiveJob(jobId: jobId) { current in
                current.updating(status: localStatus, progress: progress, lastAttemptAt: Date())
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to update remote job \(jobId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finalizeRemoteJobSuccess(
        jobId: String,
        trackId: String,
        remoteJobId: String,
        client: RemoteJobsClient
    ) async {
        do {
            guard let trackUUID = UUID(uuidString: trackId),
                  let trackBundle = try await dbManager.loadTrack(id: trackUUID) else {
                throw TranscriptionError.trackNotFound
            }

            let collectionIdStr = trackBundle.collectionId.uuidString
            let existingTranscript = try await dbManager.loadTranscript(forTrackId: trackId)
            let transcriptId: String
            if let existingTranscriptId = existingTranscript?.id {
                transcriptId = existingTranscriptId
            } else {
                transcriptId = try await ensurePendingTranscript(
                    trackId: trackId,
                    collectionId: collectionIdStr,
                    language: existingTranscript?.language ?? "en"
                )
            }

            let result = try await client.fetchSTTResult(jobId: remoteJobId)
            let srtText = result.srt ?? ""
            let transcriptText = result.transcript ?? ""
            let segments = parseSRTSegments(srtText, transcriptId: transcriptId)
            let fullText = transcriptText.isEmpty ? segments.map { $0.text }.joined(separator: "\n") : transcriptText

            let transcript = Transcript(
                id: transcriptId,
                trackId: trackId,
                collectionId: collectionIdStr,
                language: existingTranscript?.language ?? "en",
                fullText: fullText,
                createdAt: existingTranscript?.createdAt ?? Date(),
                updatedAt: Date(),
                jobStatus: "complete",
                jobId: "\(remoteJobPrefix)\(remoteJobId)",
                errorMessage: nil
            )

            try await dbManager.saveTranscript(transcript, segments: segments)
            NotificationCenter.default.post(
                name: .transcriptDidFinalize,
                object: nil,
                userInfo: [
                    "trackId": trackId,
                    "transcriptId": transcriptId
                ]
            )
            try await dbManager.markJobCompleted(jobId: jobId)
            updateActiveJob(jobId: jobId) { current in
                current.updating(status: "completed", progress: 1.0, lastAttemptAt: Date())
            }
            removeActiveJob(jobId: jobId)
        } catch {
            await markRemoteJobFailed(jobId: jobId, trackId: trackId, message: error.localizedDescription)
        }
    }

    private func markRemoteJobFailed(jobId: String, trackId: String, message: String) async {
        try? await dbManager.markJobFailed(jobId: jobId, errorMessage: message)
        removeActiveJob(jobId: jobId)
        await markTranscriptFailure(trackId: trackId, message: message)
    }

    /// Check the status of a Soniox job and update local state accordingly
    private func checkSonioxJobStatus(job: TranscriptionJob) async {
        guard let sonioxAPI = sonioxAPI else {
            logger.warning("[TranscriptionManager] Cannot check Soniox status - no API key")
            return
        }

        do {
            let status = try await sonioxAPI.checkTranscriptionStatus(transcriptionId: job.sonioxJobId)
            logger.info("[TranscriptionManager] Soniox job \(job.sonioxJobId, privacy: .public) status=\(status.status, privacy: .public)")

            switch status.status {
            case "completed":
                // Job completed while we were in background - fetch results
                logger.info("[TranscriptionManager] Job \(job.id, privacy: .public) completed in background - fetching transcript")
                let transcript = try await sonioxAPI.getTranscript(transcriptionId: job.sonioxJobId)

                // Find the transcript record to get the transcriptId
                if let existingTranscript = try await dbManager.loadTranscript(forTrackId: job.trackId) {
                    try await saveTranscriptData(
                        transcript: transcript,
                        trackId: job.trackId,
                        transcriptId: existingTranscript.id
                    )
                }

                try await dbManager.markJobCompleted(jobId: job.id)
                removeActiveJob(jobId: job.id)
                await refreshAllRecentJobs()

                // Cleanup Soniox resources
                try? await sonioxAPI.deleteTranscription(transcriptionId: job.sonioxJobId)

            case "error":
                logger.error("[TranscriptionManager] Job \(job.id, privacy: .public) failed: \(status.error_message ?? "unknown", privacy: .public)")
                try await dbManager.markJobFailed(jobId: job.id, errorMessage: status.error_message ?? "Unknown error")
                removeActiveJob(jobId: job.id)
                await refreshAllRecentJobs()

            case "processing", "queued":
                // Still processing - resume polling
                logger.info("[TranscriptionManager] Job \(job.id, privacy: .public) still processing - resuming poll")
                // Note: We don't restart the full pipeline, just update status
                // The user can manually trigger a resume if needed
                try await dbManager.updateJobStatus(jobId: job.id, status: status.status, progress: job.progress)
                updateActiveJob(jobId: job.id) { current in
                    current.updating(status: status.status, lastAttemptAt: Date())
                }

            default:
                logger.warning("[TranscriptionManager] Unknown Soniox status: \(status.status, privacy: .public)")
            }
        } catch {
            logger.error("[TranscriptionManager] Failed to check Soniox status for job \(job.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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

    private func loadRemoteJobsConfig() throws -> RemoteJobsConfig {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "remoteJobsEnabled") else {
            throw TranscriptionError.remoteJobsUnavailable
        }
        let baseURLString = (defaults.string(forKey: "remoteJobsBaseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil else {
            throw TranscriptionError.remoteJobsUnavailable
        }
        let token = defaults.string(forKey: "remoteJobsAuthToken")
        return RemoteJobsConfig(baseURL: baseURL, token: token)
    }

    private func resolveRemoteSource(for collectionId: UUID) async throws -> String {
        if let collection = try await dbManager.loadCollection(id: collectionId) {
            if case .rss = collection.source {
                return "rss"
            }
        }
        return "external"
    }

    private func parseSRTSegments(_ srtText: String, transcriptId: String) -> [TranscriptSegment] {
        let blocks = srtText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")

        var segments: [TranscriptSegment] = []

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { continue }

            let timeLineIndex: Int
            if lines.count >= 2, lines[1].contains("-->") {
                timeLineIndex = 1
            } else if lines[0].contains("-->") {
                timeLineIndex = 0
            } else {
                continue
            }

            let timeLine = String(lines[timeLineIndex])
            let textLines = lines.dropFirst(timeLineIndex + 1)
            let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let startMs = parseSRTTime(parts[0]),
                  let endMs = parseSRTTime(parts[1]) else { continue }

            let segment = TranscriptSegment(
                transcriptId: transcriptId,
                text: text,
                startTimeMs: startMs,
                endTimeMs: endMs,
                confidence: nil,
                speaker: nil,
                language: nil
            )
            segments.append(segment)
        }

        return segments
    }

    private func parseSRTTime(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeParts = trimmed.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard timeParts.count == 3 else { return nil }
        let hours = Double(timeParts[0]) ?? 0
        let minutes = Double(timeParts[1]) ?? 0
        let seconds = Double(timeParts[2]) ?? 0
        let totalSeconds = hours * 3600 + minutes * 60 + seconds
        return Int(totalSeconds * 1000)
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
