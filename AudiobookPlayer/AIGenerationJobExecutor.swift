import Foundation
import OSLog

actor AIGenerationJobExecutor {
    private let dbManager: GRDBDatabaseManager
    private let gatewayClient: AIGatewayClient
    private let keyStore: AIGatewayAPIKeyStore
    private let transcriptRepairManager: AITranscriptRepairManager
    private let trackSummaryGenerator: TrackSummaryGenerator
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "AIGenerationExecutor")
    private var isProcessing = false

    init(
        dbManager: GRDBDatabaseManager = .shared,
        gatewayClient: AIGatewayClient = AIGatewayClient(),
        keyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore(),
        transcriptRepairManager: AITranscriptRepairManager = AITranscriptRepairManager(),
        trackSummaryGenerator: TrackSummaryGenerator = TrackSummaryGenerator()
    ) {
        self.dbManager = dbManager
        self.gatewayClient = gatewayClient
        self.keyStore = keyStore
        self.transcriptRepairManager = transcriptRepairManager
        self.trackSummaryGenerator = trackSummaryGenerator
    }

    func scheduleProcessing() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        defer { isProcessing = false }

        while true {
            do {
                guard let job = try await dbManager.dequeueNextQueuedAIGenerationJob() else {
                    break
                }
                logger.debug("Processing AI job \(job.id, privacy: .public) [type=\(job.type.rawValue, privacy: .public)]")
                do {
                    try await handle(job: job)
                } catch {
                    logger.error("AI job \(job.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? await dbManager.markAIGenerationJobFailed(jobId: job.id, errorMessage: error.localizedDescription)
                }
            } catch {
                logger.error("Failed to dequeue AI job: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    private func handle(job: AIGenerationJob) async throws {
        switch job.type {
        case .chatTester:
            try await handleChatTester(job)
        case .transcriptRepair:
            try await handleTranscriptRepair(job)
        case .trackSummary:
            try await handleTrackSummary(job)
        }
    }

    // MARK: - Chat Tester

    private func handleChatTester(_ job: AIGenerationJob) async throws {
        guard let prompt = job.userPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayRequestError(message: "Prompt is empty.")
        }
        guard let modelId = job.modelId else {
            throw AIGatewayRequestError(message: "Model is not set.")
        }
        guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
        }

        let systemPrompt = job.systemPrompt ?? ""
        let payload = job.decodedPayload(ChatTesterJobPayload.self)
        let temperature = payload?.temperature ?? 0.7
        var streamBuffer = job.streamedOutput ?? ""
        var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.05)

        let response = try await gatewayClient.sendChat(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userPrompt: prompt,
            temperature: temperature,
            onStreamDelta: { [weak self] delta in
                guard let self else { return }
                Task {
                    guard !delta.isEmpty else { return }
                    streamBuffer.append(delta)
                    do {
                        try await self.dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: streamBuffer)
                    } catch {
                        self.logger.error("Failed to update AI stream: \(error.localizedDescription, privacy: .public)")
                    }
                }
            },
            onStreamFallback: { [weak self] in
                guard let self else { return }
                Task {
                    metadata = metadata.updatingFlag("stream_fallback", value: true)
                    if let json = self.encodeMetadata(metadata) {
                        try? await self.dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
                    }
                }
            }
        )

        let content = response.choices.first?.message.content ?? streamBuffer
        let usageSnapshot = AIGenerationUsageSnapshot(
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens,
            totalTokens: response.usage?.totalTokens,
            cost: response.usage?.cost
        )

        try await dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: content)
        let usageJSON = encodeUsage(usageSnapshot)
        try await dbManager.markAIGenerationJobCompleted(jobId: job.id, finalOutput: content, usageJSON: usageJSON)
    }

    // MARK: - Transcript Repair

    private func handleTranscriptRepair(_ job: AIGenerationJob) async throws {
        guard let payload = job.decodedPayload(TranscriptRepairJobPayload.self) else {
            throw AIGatewayRequestError(message: "Repair payload missing")
        }
        guard let modelId = job.modelId else {
            throw AIGatewayRequestError(message: "Model is not set.")
        }
        guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
        }

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.1)

        let segments = try await dbManager.loadTranscriptSegments(forTranscriptId: payload.transcriptId)
        let selections = payload.selectionIndexes.compactMap { index -> TranscriptRepairSelection? in
            guard segments.indices.contains(index) else { return nil }
            return TranscriptRepairSelection(displayIndex: index, segment: segments[index])
        }

        guard !selections.isEmpty else {
            throw AIGatewayRequestError(message: "No valid transcript segments were found for repair.")
        }

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.3)

        let results = try await transcriptRepairManager.repairSegments(
            transcriptId: payload.transcriptId,
            trackTitle: payload.trackTitle,
            collectionTitle: payload.collectionTitle,
            collectionDescription: payload.collectionDescription,
            selections: selections,
            model: modelId,
            apiKey: apiKey
        )

        let summaryText: String
        if results.isEmpty {
            summaryText = "No transcript changes were necessary."
        } else {
            let summaryLines = results.map { result in
                "#\(result.displayIndex): \(result.repairedText)"
            }
            summaryText = (payload.instructions?.appending("\n\n") ?? "") + summaryLines.joined(separator: "\n")
        }

        var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()
        metadata = metadata.updatingRepairResults(results)
        if let json = encodeMetadata(metadata) {
            try await dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
        }

        try await dbManager.markAIGenerationJobCompleted(jobId: job.id, finalOutput: summaryText, usageJSON: nil)
    }

    // MARK: - Track Summary Placeholder

    private func handleTrackSummary(_ job: AIGenerationJob) async throws {
        guard let payload = job.decodedPayload(TrackSummaryJobPayload.self) else {
            throw AIGatewayRequestError(message: "Track summary payload missing.")
        }
        guard let modelId = job.modelId else {
            throw AIGatewayRequestError(message: "Model is not set.")
        }
        guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
        }

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.05)

        var loadedTranscript: Transcript?

        do {
            try await dbManager.initializeDatabase()

            guard let transcript = try await dbManager.loadTranscript(forTrackId: payload.trackId) else {
                throw AIGatewayRequestError(message: "Transcript not found for track.")
            }
            loadedTranscript = transcript

            let segments = try await dbManager.loadTranscriptSegments(forTranscriptId: transcript.id)
            guard !segments.isEmpty else {
                throw AIGatewayRequestError(message: "Transcript has no segments to summarize.")
            }

            guard let trackUUID = UUID(uuidString: payload.trackId),
                  let trackBundle = try await dbManager.loadTrack(id: trackUUID) else {
                throw AIGatewayRequestError(message: "Track metadata missing.")
            }
            let track = trackBundle.track
            let collection = try await dbManager.loadCollection(id: trackBundle.collectionId)

            let context = TrackSummaryPromptContext(
                trackTitle: track.displayName,
                trackDuration: track.duration,
                trackAuthor: track.metadata["artist"] ?? track.metadata["author"],
                collectionTitle: collection?.title,
                collectionDescription: collection?.description,
                transcriptLanguage: transcript.language,
                segments: segments,
                targetSectionCount: payload.targetSectionCount,
                includeKeywords: payload.includeKeywords
            )

            let prompts = trackSummaryGenerator.makePrompts(from: context)
            var streamBuffer = job.streamedOutput ?? ""
            var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()

            try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.2)

            let response = try await gatewayClient.sendChat(
                apiKey: apiKey,
                model: modelId,
                systemPrompt: prompts.systemPrompt,
                userPrompt: prompts.userPrompt,
                temperature: 0.3,
                onStreamDelta: { [weak self] delta in
                    guard let self else { return }
                    Task {
                        guard !delta.isEmpty else { return }
                        streamBuffer.append(delta)
                        do {
                            try await self.dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: streamBuffer)
                        } catch {
                            self.logger.error("Failed updating summary stream: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                },
                onStreamFallback: { [weak self] in
                    guard let self else { return }
                    Task {
                        metadata = metadata.updatingFlag("stream_fallback", value: true)
                        if let json = self.encodeMetadata(metadata) {
                            try? await self.dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
                        }
                    }
                }
            )

            let rawText = response.choices.first?.message.content ?? streamBuffer
            try await dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: rawText)

            let parsed = try trackSummaryGenerator.parseResponse(rawText)
            let sections = parsed.sections.enumerated().map { index, payload in
                TrackSummarySection(
                    trackSummaryId: transcript.trackId,
                    orderIndex: index,
                    startTimeMs: payload.startTimeMs,
                    endTimeMs: payload.endTimeMs,
                    title: payload.title,
                    summary: payload.summary,
                    keywords: payload.keywords
                )
            }

            _ = try await dbManager.persistTrackSummaryResult(
                trackId: payload.trackId,
                transcriptId: transcript.id,
                language: transcript.language,
                summaryTitle: parsed.summaryTitle,
                summaryBody: parsed.summaryBody,
                keywords: parsed.keywords,
                sections: sections,
                modelIdentifier: modelId,
                jobId: job.id
            )

            if let json = encodeMetadata(metadata) {
                try await dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
            }

            let usageSnapshot = AIGenerationUsageSnapshot(
                promptTokens: response.usage?.promptTokens,
                completionTokens: response.usage?.completionTokens,
                totalTokens: response.usage?.totalTokens,
                cost: response.usage?.cost
            )
            let usageJSON = encodeUsage(usageSnapshot)

            let preview = [
                parsed.summaryTitle ?? track.displayName,
                parsed.summaryBody
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n\n")
            try await dbManager.markAIGenerationJobCompleted(jobId: job.id, finalOutput: preview, usageJSON: usageJSON)
        } catch {
            let transcriptId = payload.transcriptId
            let language = loadedTranscript?.language ?? "en"
            try? await dbManager.markTrackSummaryFailed(
                trackId: payload.trackId,
                transcriptId: transcriptId,
                language: language,
                message: error.localizedDescription,
                jobId: job.id
            )
            throw error
        }
    }

    // MARK: - Helpers

    nonisolated private func encodeMetadata(_ metadata: AIGenerationJobMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private func encodeUsage(_ usage: AIGenerationUsageSnapshot?) -> String? {
        guard let usage else { return nil }
        guard let data = try? JSONEncoder().encode(usage) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
