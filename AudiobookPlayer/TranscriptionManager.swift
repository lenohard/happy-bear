import Foundation
import GRDB

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

    private let sonioxAPI: SonioxAPI?
    private let dbQueue: DatabaseQueue?
    private let pollingInterval: TimeInterval = 2.0  // Poll every 2 seconds
    private let maxPollingDuration: TimeInterval = 3600  // Max 1 hour
    private var pollingTask: Task<Void, Never>?

    init(databaseQueue: DatabaseQueue?, sonioxAPIKey: String? = nil) {
        self.dbQueue = databaseQueue

        // Try to load API key from Info.plist if not provided
        let apiKey = sonioxAPIKey ?? {
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
        context: String? = nil
    ) async throws {
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

        do {
            // Create initial transcript record
            let transcript = Transcript(
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                language: languageHints.first ?? "en",
                jobStatus: "pending"
            )

            try await saveTranscript(transcript)
            DispatchQueue.main.async { self.transcriptionProgress = 0.1 }

            // Step 1: Upload file
            let fileId = try await sonioxAPI.uploadFile(fileURL: audioFileURL)
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

            // Step 3: Poll for completion
            try await pollForCompletion(
                transcriptionId: transcriptionId,
                trackId: trackIdStr,
                collectionId: collectionIdStr,
                fileId: fileId,
                sonioxAPI: sonioxAPI
            )

            // Cleanup succeeded
            try? await sonioxAPI.deleteTranscription(transcriptionId: transcriptionId)
            try? await sonioxAPI.deleteFile(fileId: fileId)

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
            throw error
        }
    }

    /// Retrieve transcript for a track
    /// - Parameter trackId: UUID of the track
    /// - Returns: Transcript if available, nil otherwise
    func getTranscript(trackId: UUID) async throws -> Transcript? {
        guard let dbQueue = dbQueue else {
            throw TranscriptionError.databaseError("Database not initialized")
        }

        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.asyncRead { db in
                do {
                    let transcript = try Transcript
                        .filter(Column("track_id") == trackId.uuidString)
                        .fetchOne(db)
                    continuation.resume(returning: transcript)
                } catch {
                    continuation.resume(throwing: TranscriptionError.databaseError(error.localizedDescription))
                }
            }
        }
    }

    /// Retrieve all segments for a transcript
    /// - Parameter transcriptId: UUID of the transcript
    /// - Returns: Array of transcript segments
    func getTranscriptSegments(transcriptId: String) async throws -> [TranscriptSegment] {
        guard let dbQueue = dbQueue else {
            throw TranscriptionError.databaseError("Database not initialized")
        }

        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.asyncRead { db in
                do {
                    let segments = try TranscriptSegment
                        .filter(Column("transcript_id") == transcriptId)
                        .order(Column("start_time_ms"))
                        .fetchAll(db)
                    continuation.resume(returning: segments)
                } catch {
                    continuation.resume(throwing: TranscriptionError.databaseError(error.localizedDescription))
                }
            }
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

        return segments
            .filter { $0.text.lowercased().contains(lowercaseQuery) }
            .map { segment in
                TranscriptSearchResult(
                    segment: segment,
                    matchedText: highlightMatch(in: segment.text, query: query)
                )
            }
    }

    // MARK: - Private Helpers

    private func saveTranscript(_ transcript: Transcript) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionError.databaseError("Database not initialized")
        }

        try await withCheckedThrowingContinuation { continuation in
            dbQueue.asyncWrite { db in
                do {
                    try transcript.insert(db)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: TranscriptionError.databaseError(error.localizedDescription))
                }
            }
        }
    }

    private func updateTranscriptJobId(trackId: String, jobId: String, status: String) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionError.databaseError("Database not initialized")
        }

        try await withCheckedThrowingContinuation { continuation in
            dbQueue.asyncWrite { db in
                do {
                    try db.execute(
                        sql: """
                        UPDATE transcripts
                        SET job_id = ?, job_status = ?, updated_at = ?
                        WHERE track_id = ?
                        """,
                        arguments: [jobId, status, Date(), trackId]
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: TranscriptionError.databaseError(error.localizedDescription))
                }
            }
        }
    }

    private func pollForCompletion(
        transcriptionId: String,
        trackId: String,
        collectionId: String,
        fileId: String,
        sonioxAPI: SonioxAPI
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
                        collectionId: collectionId
                    )

                    DispatchQueue.main.async {
                        self.transcriptionProgress = 1.0
                    }
                    return
                } else if status.status == "error" {
                    throw TranscriptionError.transcriptionFailed(status.error_message ?? "Unknown error")
                } else if status.status == "processing" || status.status == "queued" {
                    // Update progress (simple linear estimate)
                    let elapsed = Date().timeIntervalSince(startTime)
                    let estimatedProgress = 0.3 + (elapsed / maxPollingDuration) * 0.6
                    DispatchQueue.main.async {
                        self.transcriptionProgress = min(estimatedProgress, 0.9)
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
        collectionId: String
    ) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionError.databaseError("Database not initialized")
        }

        // Group tokens into segments (by speaker or time gap)
        let segments = groupTokensIntoSegments(transcript.tokens)

        // Build full text
        let fullText = segments.map { $0.text }.joined(separator: " ")

        try await withCheckedThrowingContinuation { continuation in
            dbQueue.asyncWrite { db in
                do {
                    // Update transcript with completion status and full text
                    try db.execute(
                        sql: """
                        UPDATE transcripts
                        SET full_text = ?, job_status = ?, updated_at = ?
                        WHERE track_id = ?
                        """,
                        arguments: [fullText, "complete", Date(), trackId]
                    )

                    // Insert segments
                    for segment in segments {
                        try segment.insert(db)
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: TranscriptionError.databaseError(error.localizedDescription))
                }
            }
        }
    }

    private func groupTokensIntoSegments(_ tokens: [SonioxToken]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentSegment: (texts: [String], startMs: Int, endMs: Int, speaker: String?, language: String?)? = nil

        let gapThresholdMs = 1500  // 1.5 second gap = new segment

        for token in tokens {
            let startMs = token.start_ms ?? 0
            let endMs = token.end_ms ?? startMs
            let text = token.text
            let speaker = token.speaker ?? "unknown"
            let language = token.language

            if currentSegment == nil {
                currentSegment = (texts: [text], startMs: startMs, endMs: endMs, speaker: speaker, language: language)
            } else if let current = currentSegment {
                let gapSize = startMs - current.endMs
                let speakerChanged = speaker != current.speaker
                let languageChanged = language != current.language

                if gapSize > gapThresholdMs || speakerChanged {
                    // Save current segment and start new one
                    let fullText = current.texts.joined(separator: "")
                    let segment = TranscriptSegment(
                        transcriptId: "",  // Will be set by caller
                        text: fullText,
                        startTimeMs: current.startMs,
                        endTimeMs: current.endMs,
                        speaker: current.speaker,
                        language: current.language
                    )
                    segments.append(segment)

                    currentSegment = (texts: [text], startMs: startMs, endMs: endMs, speaker: speaker, language: language)
                } else {
                    // Continue current segment
                    currentSegment?.texts.append(text)
                    currentSegment?.endMs = endMs
                }
            }
        }

        // Save last segment
        if let current = currentSegment {
            let fullText = current.texts.joined(separator: "")
            let segment = TranscriptSegment(
                transcriptId: "",  // Will be set by caller
                text: fullText,
                startTimeMs: current.startMs,
                endTimeMs: current.endMs,
                speaker: current.speaker,
                language: current.language
            )
            segments.append(segment)
        }

        return segments
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

// MARK: - Search Result

struct TranscriptSearchResult: Identifiable {
    let id = UUID()
    let segment: TranscriptSegment
    let matchedText: String
}
