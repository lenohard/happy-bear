import Foundation

// MARK: - Transcript Models for GRDB

/// A complete transcript for a track
/// Stored in database and retrieved for searching/viewing
struct Transcript: Identifiable, Codable {
    let id: String  // UUID string
    let trackId: String  // FK to AudiobookTrack.id
    let collectionId: String  // FK to AudiobookCollection.id
    let language: String  // "en", "zh", etc.
    let fullText: String  // Complete transcript (concatenated from all segments)
    let createdAt: Date
    let updatedAt: Date
    let jobStatus: String  // "pending", "processing", "complete", "failed"
    let jobId: String?  // Soniox job ID for tracking/cleanup
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case collectionId = "collection_id"
        case language
        case fullText = "full_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case jobStatus = "job_status"
        case jobId = "job_id"
        case errorMessage = "error_message"
    }

    init(
        id: String = UUID().uuidString,
        trackId: String,
        collectionId: String,
        language: String = "en",
        fullText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        jobStatus: String = "pending",
        jobId: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.collectionId = collectionId
        self.language = language
        self.fullText = fullText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.jobStatus = jobStatus
        self.jobId = jobId
        self.errorMessage = errorMessage
    }
}

/// A segment of transcript with timing information
/// Each segment represents a contiguous speech segment (may be speaker-based)
struct TranscriptSegment: Identifiable, Codable {
    let id: String  // UUID string
    let transcriptId: String  // FK to Transcript.id
    let text: String  // Segment text
    let startTimeMs: Int  // Milliseconds
    let endTimeMs: Int  // Milliseconds
    let confidence: Double?  // 0.0 - 1.0
    let speaker: String?  // Speaker identifier from diarization
    let language: String?  // Detected language for this segment
    let lastRepairModel: String?
    let lastRepairAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case transcriptId = "transcript_id"
        case text
        case startTimeMs = "start_time_ms"
        case endTimeMs = "end_time_ms"
        case confidence
        case speaker
        case language
        case lastRepairModel = "last_repair_model"
        case lastRepairAt = "last_repair_at"
    }

    init(
        id: String = UUID().uuidString,
        transcriptId: String,
        text: String,
        startTimeMs: Int,
        endTimeMs: Int,
        confidence: Double? = nil,
        speaker: String? = nil,
        language: String? = nil,
        lastRepairModel: String? = nil,
        lastRepairAt: Date? = nil
    ) {
        self.id = id
        self.transcriptId = transcriptId
        self.text = text
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.confidence = confidence
        self.speaker = speaker
        self.language = language
        self.lastRepairModel = lastRepairModel
        self.lastRepairAt = lastRepairAt
    }

    /// Duration of this segment in milliseconds
    var durationMs: Int {
        endTimeMs - startTimeMs
    }

    /// Formatted start time (HH:MM:SS.mmm)
    var formattedStartTime: String {
        formatTimeMs(startTimeMs)
    }

    /// Formatted end time (HH:MM:SS.mmm)
    var formattedEndTime: String {
        formatTimeMs(endTimeMs)
    }

    private func formatTimeMs(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

/// Metadata about a transcription job
/// Tracks the state of transcription process
struct TranscriptionJob: Identifiable, Codable {
    let id: String  // UUID string
    let trackId: String  // FK to AudiobookTrack.id
    let sonioxJobId: String  // Soniox job ID
    let status: String  // "queued", "downloading", "uploading", "transcribing", "processing", "completed", "failed"
    let progress: Double?  // 0.0 - 1.0 (estimated)
    let createdAt: Date
    let completedAt: Date?
    let errorMessage: String?
    let retryCount: Int  // Number of retry attempts
    let lastAttemptAt: Date?
    let totalParagraphs: Int?
    let processedParagraphs: Int?
    let pendingParagraphs: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case sonioxJobId = "soniox_job_id"
        case status
        case progress
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case errorMessage = "error_message"
        case retryCount = "retry_count"
        case lastAttemptAt = "last_attempt_at"
        case totalParagraphs = "total_paragraphs"
        case processedParagraphs = "processed_paragraphs"
        case pendingParagraphs = "pending_paragraphs"
    }

    init(
        id: String = UUID().uuidString,
        trackId: String,
        sonioxJobId: String,
        status: String = "queued",
        progress: Double? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil,
        totalParagraphs: Int? = nil,
        processedParagraphs: Int? = nil,
        pendingParagraphs: Int? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.sonioxJobId = sonioxJobId
        self.status = status
        self.progress = progress
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
        self.totalParagraphs = totalParagraphs
        self.processedParagraphs = processedParagraphs
        self.pendingParagraphs = pendingParagraphs
    }

    /// Whether the job is still running
    var isRunning: Bool {
        status == "queued" || status == "downloading" || status == "uploading" || status == "transcribing" || status == "processing"
    }

    /// Whether the job has completed successfully
    var isCompleted: Bool {
        status == "completed"
    }

    /// Whether the job has failed
    var isFailed: Bool {
        status == "failed"
    }
}

extension TranscriptionJob {
    func updating(
        status: String? = nil,
        progress: Double? = nil,
        errorMessage: String? = nil,
        sonioxJobId: String? = nil,
        lastAttemptAt: Date? = nil,
        totalParagraphs: Int? = nil,
        processedParagraphs: Int? = nil
    ) -> TranscriptionJob {
        TranscriptionJob(
            id: id,
            trackId: trackId,
            sonioxJobId: sonioxJobId ?? self.sonioxJobId,
            status: status ?? self.status,
            progress: progress ?? self.progress,
            createdAt: createdAt,
            completedAt: completedAt,
            errorMessage: errorMessage ?? self.errorMessage,
            retryCount: retryCount,
            lastAttemptAt: lastAttemptAt ?? self.lastAttemptAt,
            totalParagraphs: totalParagraphs ?? self.totalParagraphs,
            processedParagraphs: processedParagraphs ?? self.processedParagraphs
        )
    }
}

// MARK: - DTO Models for Database Operations

/// Data Transfer Object for transcripts
struct TranscriptRow: Codable {
    let id: String
    let trackId: String
    let collectionId: String
    let language: String
    let fullText: String
    let createdAt: Date
    let updatedAt: Date
    let jobStatus: String
    let jobId: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case collectionId = "collection_id"
        case language
        case fullText = "full_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case jobStatus = "job_status"
        case jobId = "job_id"
        case errorMessage = "error_message"
    }

    init(from transcript: Transcript) {
        self.id = transcript.id
        self.trackId = transcript.trackId
        self.collectionId = transcript.collectionId
        self.language = transcript.language
        self.fullText = transcript.fullText
        self.createdAt = transcript.createdAt
        self.updatedAt = transcript.updatedAt
        self.jobStatus = transcript.jobStatus
        self.jobId = transcript.jobId
        self.errorMessage = transcript.errorMessage
    }
}

/// Data Transfer Object for transcript segments
struct TranscriptSegmentRow: Codable {
    let id: String
    let transcriptId: String
    let text: String
    let startTimeMs: Int
    let endTimeMs: Int
    let confidence: Double?
    let speaker: String?
    let language: String?
    let lastRepairModel: String?
    let lastRepairAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case transcriptId = "transcript_id"
        case text
        case startTimeMs = "start_time_ms"
        case endTimeMs = "end_time_ms"
        case confidence
        case speaker
        case language
        case lastRepairModel = "last_repair_model"
        case lastRepairAt = "last_repair_at"
    }

    init(from segment: TranscriptSegment) {
        self.id = segment.id
        self.transcriptId = segment.transcriptId
        self.text = segment.text
        self.startTimeMs = segment.startTimeMs
        self.endTimeMs = segment.endTimeMs
        self.confidence = segment.confidence
        self.speaker = segment.speaker
        self.language = segment.language
        self.lastRepairModel = segment.lastRepairModel
        self.lastRepairAt = segment.lastRepairAt
    }
}

// MARK: - Transcript Search Result

struct TranscriptSearchResult: Identifiable {
    let id: String
    let segmentIndex: Int
    let segment: TranscriptSegment
    let matchCount: Int
    let matchedText: String?

    init(
        id: String = UUID().uuidString,
        segmentIndex: Int,
        segment: TranscriptSegment,
        matchCount: Int,
        matchedText: String? = nil
    ) {
        self.id = id
        self.segmentIndex = segmentIndex
        self.segment = segment
        self.matchCount = max(1, matchCount)
        self.matchedText = matchedText
    }

    var displayText: String {
        "Found \(matchCount) match\(matchCount == 1 ? "" : "es") at \(segment.formattedStartTime)"
    }
}

/// Data Transfer Object for transcription jobs
struct TranscriptionJobRow: Codable {
    let id: String
    let trackId: String
    let sonioxJobId: String
    let status: String
    let progress: Double?
    let createdAt: Date
    let completedAt: Date?
    let errorMessage: String?
    let retryCount: Int
    let lastAttemptAt: Date?
    let totalParagraphs: Int?
    let processedParagraphs: Int?
    let pendingParagraphs: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case sonioxJobId = "soniox_job_id"
        case status
        case progress
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case errorMessage = "error_message"
        case retryCount = "retry_count"
        case lastAttemptAt = "last_attempt_at"
        case totalParagraphs = "total_paragraphs"
        case processedParagraphs = "processed_paragraphs"
        case pendingParagraphs = "pending_paragraphs"
    }

    init(from job: TranscriptionJob) {
        self.id = job.id
        self.trackId = job.trackId
        self.sonioxJobId = job.sonioxJobId
        self.status = job.status
        self.progress = job.progress
        self.createdAt = job.createdAt
        self.completedAt = job.completedAt
        self.errorMessage = job.errorMessage
        self.retryCount = job.retryCount
        self.lastAttemptAt = job.lastAttemptAt
        self.totalParagraphs = job.totalParagraphs
        self.processedParagraphs = job.processedParagraphs
        self.pendingParagraphs = job.pendingParagraphs
    }
}

// MARK: - Track Summary Models

/// A generated summary for a track's transcript
struct TrackSummary: Identifiable, Codable {
    enum Status: String, Codable {
        case idle
        case generating
        case failed
        case complete
    }

    let id: String
    let trackId: String
    let transcriptId: String
    let language: String
    var summaryTitle: String?
    var summaryBody: String?
    var keywords: [String]
    var mentionedItems: [String]
    var suggestedCorrections: [String: String]
    var sectionCount: Int
    var modelIdentifier: String?
    var generatedAt: Date?
    var status: Status
    var errorMessage: String?
    var lastJobId: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        trackId: String,
        transcriptId: String,
        language: String = "en",
        summaryTitle: String? = nil,
        summaryBody: String? = nil,
        keywords: [String] = [],
        mentionedItems: [String] = [],
        suggestedCorrections: [String: String] = [:],
        sectionCount: Int = 0,
        modelIdentifier: String? = nil,
        generatedAt: Date? = nil,
        status: Status = .idle,
        errorMessage: String? = nil,
        lastJobId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trackId = trackId
        self.transcriptId = transcriptId
        self.language = language
        self.summaryTitle = summaryTitle
        self.summaryBody = summaryBody
        self.keywords = keywords
        self.mentionedItems = mentionedItems
        self.suggestedCorrections = suggestedCorrections
        self.sectionCount = sectionCount
        self.modelIdentifier = modelIdentifier
        self.generatedAt = generatedAt
        self.status = status
        self.errorMessage = errorMessage
        self.lastJobId = lastJobId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isReady: Bool {
        status == .complete && summaryBody?.isEmpty == false
    }
}

/// Individual summary sections with timestamps
struct TrackSummarySection: Identifiable, Codable {
    let id: String
    let trackSummaryId: String
    var orderIndex: Int
    var startTimeMs: Int
    var endTimeMs: Int?
    var title: String?
    var summary: String
    var keywords: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        trackSummaryId: String,
        orderIndex: Int,
        startTimeMs: Int,
        endTimeMs: Int? = nil,
        title: String? = nil,
        summary: String,
        keywords: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trackSummaryId = trackSummaryId
        self.orderIndex = orderIndex
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.title = title
        self.summary = summary
        self.keywords = keywords
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var startTimeLabel: String {
        let seconds = startTimeMs / 1000
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Transcript Correction Models

/// A correction suggestion for transcript typos
/// Tracks whether the correction has been applied to the transcript
struct TranscriptCorrection: Identifiable, Codable {
    let id: String
    let trackId: String
    let incorrectText: String
    let correctText: String
    var isApplied: Bool
    var appliedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case incorrectText = "incorrect_text"
        case correctText = "correct_text"
        case isApplied = "is_applied"
        case appliedAt = "applied_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    init(
        id: String = UUID().uuidString,
        trackId: String,
        incorrectText: String,
        correctText: String,
        isApplied: Bool = false,
        appliedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trackId = trackId
        self.incorrectText = incorrectText
        self.correctText = correctText
        self.isApplied = isApplied
        self.appliedAt = appliedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Data Transfer Object for transcript corrections
struct TranscriptCorrectionRow: Codable {
    let id: String
    let trackId: String
    let incorrectText: String
    let correctText: String
    let isApplied: Bool
    let appliedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    
    private enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case incorrectText = "incorrect_text"
        case correctText = "correct_text"
        case isApplied = "is_applied"
        case appliedAt = "applied_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    init(from correction: TranscriptCorrection) {
        self.id = correction.id
        self.trackId = correction.trackId
        self.incorrectText = correction.incorrectText
        self.correctText = correction.correctText
        self.isApplied = correction.isApplied
        self.appliedAt = correction.appliedAt
        self.createdAt = correction.createdAt
        self.updatedAt = correction.updatedAt
    }
}
