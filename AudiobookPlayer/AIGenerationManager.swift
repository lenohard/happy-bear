import Foundation
import OSLog

@MainActor
final class AIGenerationManager: ObservableObject {
    @Published private(set) var activeJobs: [AIGenerationJob] = []
    @Published private(set) var recentJobs: [AIGenerationJob] = []

    private let dbManager: GRDBDatabaseManager
    private let executor: AIGenerationJobExecutor
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "AIGenerationManager")
    private var refreshTask: Task<Void, Never>?

    init(
        dbManager: GRDBDatabaseManager = .shared,
        executor: AIGenerationJobExecutor = AIGenerationJobExecutor()
    ) {
        self.dbManager = dbManager
        self.executor = executor
        bootstrapJobs()
        startRefreshLoop()
    }

    deinit {
        refreshTask?.cancel()
    }

    func enqueueChatTesterJob(
        prompt: String,
        systemPrompt: String,
        temperature: Double,
        modelId: String,
        reasoning: AIGatewayReasoningConfig? = nil,
        displayName: String? = nil
    ) async throws -> AIGenerationJob {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_generation_empty", comment: ""))
        }

        try await dbManager.initializeDatabase()

        let payload = ChatTesterJobPayload(temperature: temperature, reasoning: reasoning)
        let payloadJSON = try encodeJSON(payload)

        let job = try await dbManager.createAIGenerationJob(
            type: .chatTester,
            modelId: modelId,
            trackId: nil,
            transcriptId: nil,
            sourceContext: "ai_tab_tester",
            displayName: displayName,
            systemPrompt: systemPrompt,
            userPrompt: trimmedPrompt,
            payloadJSON: payloadJSON
        )

        await executor.scheduleProcessing()
        await refreshJobs()
        return job
    }

    func deleteJob(_ job: AIGenerationJob) async {
        try? await dbManager.deleteAIGenerationJob(jobId: job.id)
        await refreshJobs()
    }

    func cancelJob(_ job: AIGenerationJob) async {
        do {
            try await dbManager.initializeDatabase()
            let canceled = try await dbManager.cancelQueuedAIGenerationJob(jobId: job.id)
            if !canceled {
                logger.info("AI job \(job.id, privacy: .public) could not be canceled (status=\(job.status.rawValue, privacy: .public))")
            }
            await refreshJobs()
        } catch {
            logger.error("Failed to cancel AI job: \(error.localizedDescription, privacy: .public)")
        }
    }

    func enqueueTrackSummaryJob(
        trackId: String,
        targetSectionCount: Int? = nil,
        includeKeywords: Bool = true,
        modelId: String
    ) async throws -> AIGenerationJob {
        guard !trackId.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("track_summary_missing_track", comment: ""))
        }
        guard let trackUUID = UUID(uuidString: trackId) else {
            throw AIGatewayRequestError(message: NSLocalizedString("track_summary_missing_track", comment: ""))
        }

        try await dbManager.initializeDatabase()

        guard let transcript = try await dbManager.loadTranscript(forTrackId: trackId) else {
            throw AIGatewayRequestError(message: NSLocalizedString("track_summary_requires_transcript", comment: "Track transcript not found"))
        }

        let normalizedStatus = transcript.jobStatus.lowercased()
        guard normalizedStatus == "complete" || normalizedStatus == "completed" else {
            throw AIGatewayRequestError(message: NSLocalizedString("track_summary_transcript_not_ready", comment: "Transcript not completed"))
        }

        var displayName: String?
        if let trackBundle = try await dbManager.loadTrack(id: trackUUID) {
            displayName = trackBundle.track.displayName
        }

        let payload = TrackSummaryJobPayload(
            transcriptId: transcript.id,
            trackId: trackId,
            targetSectionCount: targetSectionCount,
            includeKeywords: includeKeywords
        )
        let payloadJSON = try encodeJSON(payload)

        let job = try await dbManager.createAIGenerationJob(
            type: .trackSummary,
            modelId: modelId,
            trackId: trackId,
            transcriptId: transcript.id,
            sourceContext: "track_summary",
            displayName: displayName,
            systemPrompt: nil,
            userPrompt: nil,
            payloadJSON: payloadJSON
        )

        _ = try await dbManager.upsertTrackSummaryState(
            trackId: trackId,
            transcriptId: transcript.id,
            language: transcript.language,
            status: .generating,
            modelIdentifier: modelId,
            jobId: job.id,
            errorMessage: nil
        )

        await executor.scheduleProcessing()
        await refreshJobs()
        return job
    }

    func enqueueTranscriptRepairJob(
        transcriptId: String,
        trackId: String,
        trackTitle: String,
        collectionTitle: String?,
        collectionDescription: String?,
        selectionIndexes: [Int],
        instructions: String?,
        modelId: String
    ) async throws -> AIGenerationJob {
        guard !selectionIndexes.isEmpty else {
            throw AIGatewayRequestError(message: "No valid segments selected for repair.")
        }

        try await dbManager.initializeDatabase()

        let payload = TranscriptRepairJobPayload(
            transcriptId: transcriptId,
            trackTitle: trackTitle,
            collectionTitle: collectionTitle,
            collectionDescription: collectionDescription,
            selectionIndexes: selectionIndexes,
            instructions: instructions
        )
        let payloadJSON = try encodeJSON(payload)

        let job = try await dbManager.createAIGenerationJob(
            type: .transcriptRepair,
            modelId: modelId,
            trackId: trackId,
            transcriptId: transcriptId,
            sourceContext: "transcript_viewer",
            displayName: trackTitle,
            systemPrompt: nil,
            userPrompt: nil,
            payloadJSON: payloadJSON
        )

        await executor.scheduleProcessing()
        await refreshJobs()
        return job
    }

    func job(withId id: String) -> AIGenerationJob? {
        if let active = activeJobs.first(where: { $0.id == id }) {
            return active
        }
        return recentJobs.first(where: { $0.id == id })
    }

    func refreshJobs() async {
        do {
            try await dbManager.initializeDatabase()
            let active = try await dbManager.loadActiveAIGenerationJobs()
            let recent = try await dbManager.loadRecentAIGenerationJobs(limit: 50)
            activeJobs = active
            recentJobs = recent
        } catch {
            logger.error("Failed to refresh AI jobs: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await self.dbManager.initializeDatabase()
            await self.refreshJobs()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.refreshJobs()
            }
        }
    }

    private func bootstrapJobs() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.dbManager.initializeDatabase()
                let interruptionMessage = NSLocalizedString("ai_tab_job_interrupted", comment: "")
                let recovered = try await self.dbManager.failInterruptedAIGenerationJobs(
                    interruptionReason: interruptionMessage
                )
                if recovered > 0 {
                    self.logger.info("Marked \(recovered) in-flight AI jobs as interrupted on launch")
                }

                if try await self.dbManager.hasQueuedAIGenerationJobs() {
                    await self.executor.scheduleProcessing()
                }

                await self.refreshJobs()
            } catch {
                self.logger.error("Failed to bootstrap AI jobs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func encodeJSON<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AIGatewayRequestError(message: "Failed to encode payload")
        }
        return string
    }

}
