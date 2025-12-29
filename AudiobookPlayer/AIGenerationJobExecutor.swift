import Foundation
import OSLog

actor AIGenerationJobExecutor {
    private let dbManager: GRDBDatabaseManager
    private let gatewayClient: AIGatewayClient
    private let keyStore: AIGatewayAPIKeyStore
    private let transcriptRepairManager: AITranscriptRepairManager
    private let trackSummaryGenerator: TrackSummaryGenerator
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "AIGenerationExecutor")
    private let remotePollingInterval: TimeInterval = 2.0
    private let remoteMaxPollingDuration: TimeInterval = 3600
    private let remoteJobMetadataKey = "remote_job_id"
    private var isProcessing = false
    
    private struct StreamBuffer {
        var content: String
        var reasoning: String
    }
    private var streamBuffers: [String: StreamBuffer] = [:]
    
    private var runningJobs: Set<String> = []
    private let maxConcurrentJobs: Int

    init(
        dbManager: GRDBDatabaseManager = .shared,
        gatewayClient: AIGatewayClient = AIGatewayClient(),
        keyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore(),
        transcriptRepairManager: AITranscriptRepairManager = AITranscriptRepairManager(),
        trackSummaryGenerator: TrackSummaryGenerator = TrackSummaryGenerator(),
        maxConcurrentJobs: Int = 3
    ) {
        self.dbManager = dbManager
        self.gatewayClient = gatewayClient
        self.keyStore = keyStore
        self.transcriptRepairManager = transcriptRepairManager
        self.trackSummaryGenerator = trackSummaryGenerator
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    func scheduleProcessing() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { [weak self] in
            await self?.processNextBatch()
        }
    }

    private func processNextBatch() async {
        defer { isProcessing = false }

        // Process jobs up to the concurrency limit
        while runningJobs.count < maxConcurrentJobs {
            do {
                guard let job = try await dbManager.dequeueNextQueuedAIGenerationJob() else {
                    break
                }
                
                runningJobs.insert(job.id)
                logger.debug("Starting AI job \(job.id, privacy: .public) [type=\(job.type.rawValue, privacy: .public)] (concurrent: \(self.runningJobs.count)/\(self.maxConcurrentJobs))")
                
                // Launch each job in its own task
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.handle(job: job)
                    } catch {
                        await self.logger.error("AI job \(job.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        try? await self.dbManager.markAIGenerationJobFailed(jobId: job.id, errorMessage: error.localizedDescription)
                    }
                    
                    // Mark job as completed and check for more work
                    await self.jobCompleted(job.id)
                }
            } catch {
                logger.error("Failed to dequeue AI job: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }
    
    private func jobCompleted(_ jobId: String) {
        runningJobs.remove(jobId)
        logger.debug("Completed AI job \(jobId, privacy: .public) (remaining: \(self.runningJobs.count))")
        
        // Try to process more jobs if slots are available
        if runningJobs.count < maxConcurrentJobs {
            scheduleProcessing()
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

        let systemPrompt = job.systemPrompt ?? ""
        let payload = job.decodedPayload(ChatTesterJobPayload.self)
        let temperature = payload?.temperature ?? 0.7
        let reasoningConfig = payload?.reasoning
        var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()

        let defaults = UserDefaults.standard
        let remoteEnabled = defaults.bool(forKey: "remoteJobsEnabled")
        let fallbackToLocal = defaults.bool(forKey: "remoteJobsFallbackToLocal")

        if remoteEnabled {
            do {
                let config = try loadRemoteJobsConfig()
                let client = RemoteJobsClient(config: config)
                try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.1)
                let remoteJob = try await client.createAIJob(
                    inputText: prompt,
                    modelId: modelId,
                    systemPrompt: systemPrompt,
                    temperature: temperature
                )
                try await persistRemoteJobId(remoteJob.id, jobId: job.id, metadata: &metadata)
                let resultText = try await pollRemoteAIJob(
                    client: client,
                    remoteJob: remoteJob,
                    jobId: job.id,
                    progressRange: 0.1...0.9
                )
                try await dbManager.markAIGenerationJobCompleted(jobId: job.id, finalOutput: resultText, usageJSON: nil)
                return
            } catch {
                if !fallbackToLocal {
                    throw error
                }
            }
        }

        guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
        }

        setInitialStreamBuffer(job.streamedOutput ?? "", reasoning: job.streamedReasoning ?? "", for: job.id)
        defer { clearStreamBuffer(for: job.id) }

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.05)

        let response = try await gatewayClient.sendChat(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userPrompt: prompt,
            temperature: temperature,
            reasoning: reasoningConfig,
            onStreamDelta: { [weak self] delta in
                guard let self else { return }
                Task {
                    await self.persistStreamDelta(delta, for: job.id)
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

        let content = response.choices.first?.message.content ?? currentContentBuffer(for: job.id)
        clearStreamBuffer(for: job.id)
        if let snapshot = reasoningSnapshot(from: response.choices.first?.message) {
            metadata = metadata.updatingReasoning(snapshot)
        }
        let usageSnapshot = AIGenerationUsageSnapshot(
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens,
            totalTokens: response.usage?.totalTokens,
            cost: response.usage?.cost,
            reasoningTokens: response.usage?.completionTokensDetails?.reasoningTokens
        )

        try await dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: content)
        let usageJSON = encodeUsage(usageSnapshot)
        if let json = encodeMetadata(metadata) {
            try await dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
        }
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
        let defaults = UserDefaults.standard
        let remoteEnabled = defaults.bool(forKey: "remoteJobsEnabled")
        let fallbackToLocal = defaults.bool(forKey: "remoteJobsFallbackToLocal")

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.1)

        let segments = try await dbManager.loadTranscriptSegments(forTranscriptId: payload.transcriptId)
        let selections = payload.selectionIndexes.compactMap { index -> TranscriptRepairSelection? in
            guard segments.indices.contains(index) else { return nil }
            return TranscriptRepairSelection(displayIndex: index, segment: segments[index])
        }

        guard !selections.isEmpty else {
            throw AIGatewayRequestError(message: "No valid transcript segments were found for repair.")
        }

        var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()
        var results: [TranscriptRepairResult] = []
        var didRunRemote = false

        if remoteEnabled {
            do {
                let config = try loadRemoteJobsConfig()
                let client = RemoteJobsClient(config: config)
                let promptBuilder = TranscriptRepairPromptBuilder(
                    trackTitle: payload.trackTitle,
                    collectionTitle: payload.collectionTitle,
                    collectionDescription: payload.collectionDescription,
                    instructions: "Clean the transcript text while keeping timestamps and speaker order untouched."
                )
                let userPrompt = promptBuilder.makeUserPrompt(from: selections)
                let remoteJob = try await client.createAIJob(
                    inputText: userPrompt,
                    modelId: modelId,
                    systemPrompt: AITranscriptRepairManager.defaultSystemPrompt,
                    temperature: 0.2
                )
                try await persistRemoteJobId(remoteJob.id, jobId: job.id, metadata: &metadata)
                let content = try await pollRemoteAIJob(
                    client: client,
                    remoteJob: remoteJob,
                    jobId: job.id,
                    progressRange: 0.2...0.8
                )

                let parser = TranscriptRepairParser()
                let parsed: TranscriptRepairResponse
                do {
                    parsed = try parser.parse(content)
                } catch {
                    throw AITranscriptRepairError.responseParseFailed
                }

                let indexMap = Dictionary(uniqueKeysWithValues: selections.map { ($0.displayIndex, $0.segment) })
                var updates: [String: String] = [:]

                for repair in parsed.repairs {
                    guard let segment = indexMap[repair.index] else {
                        throw AITranscriptRepairError.unmatchedIndexes
                    }
                    let trimmed = repair.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed != segment.text else { continue }
                    updates[segment.id] = trimmed
                    results.append(
                        TranscriptRepairResult(
                            segmentId: segment.id,
                            originalText: segment.text,
                            repairedText: trimmed,
                            displayIndex: repair.index
                        )
                    )
                }

                if !updates.isEmpty {
                    try await dbManager.applyTranscriptRepairs(
                        transcriptId: payload.transcriptId,
                        editedTextsBySegmentId: updates,
                        model: modelId
                    )
                }
                didRunRemote = true
            } catch {
                if !fallbackToLocal {
                    throw error
                }
            }
        }

        if !didRunRemote {
            guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
                throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
            }

            try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.3)
            results = try await transcriptRepairManager.repairSegments(
                transcriptId: payload.transcriptId,
                trackTitle: payload.trackTitle,
                collectionTitle: payload.collectionTitle,
                collectionDescription: payload.collectionDescription,
                selections: selections,
                model: modelId,
                apiKey: apiKey
            )
        }

        let summaryText: String
        if results.isEmpty {
            summaryText = "No transcript changes were necessary."
        } else {
            let summaryLines = results.map { result in
                "#\(result.displayIndex): \(result.repairedText)"
            }
            summaryText = (payload.instructions?.appending("\n\n") ?? "") + summaryLines.joined(separator: "\n")
        }

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
        let defaults = UserDefaults.standard
        let remoteEnabled = defaults.bool(forKey: "remoteJobsEnabled")
        let fallbackToLocal = defaults.bool(forKey: "remoteJobsFallbackToLocal")

        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.05)

        var loadedTranscript: Transcript?
        setInitialStreamBuffer(job.streamedOutput ?? "", reasoning: job.streamedReasoning ?? "", for: job.id)
        defer { clearStreamBuffer(for: job.id) }

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
                includeKeywords: payload.includeKeywords,
                requestTranslations: payload.requestTranslations
            )

            var metadata = job.decodedMetadata() ?? AIGenerationJobMetadata()
            var useRemote = false
            var remoteClient: RemoteJobsClient?
            if remoteEnabled {
                do {
                    let config = try loadRemoteJobsConfig()
                    remoteClient = RemoteJobsClient(config: config)
                    useRemote = true
                } catch {
                    if !fallbackToLocal {
                        throw error
                    }
                }
            }

            let parsed: TrackSummaryGenerationResult
            let translations: [TrackSummaryTranslation]
            var usageSnapshot: AIGenerationUsageSnapshot?

            if useRemote {
                guard let client = remoteClient else {
                    throw AIGatewayRequestError(message: "Remote jobs are not configured.")
                }
                try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .running, progress: 0.2)

                if payload.translationOnly {
                    let filteredSegments = filterTranslationSegments(segments)
                    guard !filteredSegments.isEmpty else {
                        throw AIGatewayRequestError(message: "Transcript has no valid segments to translate.")
                    }
                    let chunkSize = 200
                    let chunks = filteredSegments.chunked(into: chunkSize)
                    var chunkTranslations: [TrackSummaryTranslationPayload] = []
                    var firstChunkResult: TrackSummaryGenerationResult?

                    for (index, chunk) in chunks.enumerated() {
                        let chunkContext = TrackSummaryPromptContext(
                            trackTitle: context.trackTitle,
                            trackDuration: context.trackDuration,
                            trackAuthor: context.trackAuthor,
                            collectionTitle: context.collectionTitle,
                            collectionDescription: context.collectionDescription,
                            transcriptLanguage: context.transcriptLanguage,
                            segments: chunk,
                            targetSectionCount: context.targetSectionCount,
                            includeKeywords: context.includeKeywords,
                            requestTranslations: context.requestTranslations
                        )

                        let prompts = trackSummaryGenerator.makePrompts(from: chunkContext)
                        logger.info("[TrackSummaryTranslationOnly] Input (chunk \(index + 1)/\(chunks.count)): \(prompts.userPrompt, privacy: .public)")

                        let remoteJob = try await client.createAIJob(
                            inputText: prompts.userPrompt,
                            modelId: modelId,
                            systemPrompt: prompts.systemPrompt,
                            temperature: 0.3
                        )
                        try await persistRemoteJobId(remoteJob.id, jobId: job.id, metadata: &metadata)

                        let progressStart = 0.2 + (0.6 * Double(index) / Double(chunks.count))
                        let progressEnd = 0.2 + (0.6 * Double(index + 1) / Double(chunks.count))
                        let rawText = try await pollRemoteAIJob(
                            client: client,
                            remoteJob: remoteJob,
                            jobId: job.id,
                            progressRange: progressStart...progressEnd
                        )

                        let chunkParsed = try trackSummaryGenerator.parseTranslationOnlyResponse(rawText, segments: chunk)
                        if firstChunkResult == nil {
                            firstChunkResult = chunkParsed
                        }
                        chunkTranslations.append(contentsOf: chunkParsed.translations)
                    }

                    guard let result = firstChunkResult else {
                        throw AIGatewayRequestError(message: "Translation request returned no output.")
                    }

                    parsed = result
                    translations = chunkTranslations
                        .sorted { $0.startTimeMs < $1.startTimeMs }
                        .enumerated()
                        .map { index, payload in
                            TrackSummaryTranslation(
                                orderIndex: index,
                                startTimeMs: payload.startTimeMs,
                                translation: payload.translation
                            )
                        }
                } else {
                    let prompts = trackSummaryGenerator.makePrompts(from: context)
                    let remoteJob = try await client.createAIJob(
                        inputText: prompts.userPrompt,
                        modelId: modelId,
                        systemPrompt: prompts.systemPrompt,
                        temperature: 0.3
                    )
                    try await persistRemoteJobId(remoteJob.id, jobId: job.id, metadata: &metadata)
                    let rawText = try await pollRemoteAIJob(
                        client: client,
                        remoteJob: remoteJob,
                        jobId: job.id,
                        progressRange: 0.3...0.8
                    )

                    parsed = try trackSummaryGenerator.parseResponse(rawText)
                    translations = parsed.translations.enumerated().map { index, payload in
                        TrackSummaryTranslation(
                            orderIndex: index,
                            startTimeMs: payload.startTimeMs,
                            translation: payload.translation
                        )
                    }
                }
            } else {
                guard let apiKey = try await keyStore.loadKey(), !apiKey.isEmpty else {
                    throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_key", comment: ""))
                }

                try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: 0.2)

                let onDelta: ((AIGatewayClient.StreamDelta) -> Void) = { [weak self] delta in
                    guard let self else { return }
                    Task {
                        await self.persistStreamDelta(delta, for: job.id)
                    }
                }

                if payload.translationOnly {
                    let filteredSegments = filterTranslationSegments(segments)
                    guard !filteredSegments.isEmpty else {
                        throw AIGatewayRequestError(message: "Transcript has no valid segments to translate.")
                    }
                    let chunkSize = 200
                    let chunks = filteredSegments.chunked(into: chunkSize)
                    var chunkTranslations: [TrackSummaryTranslationPayload] = []
                    var firstChunkResult: TrackSummaryGenerationResult?
                    var accumulatedUsage = UsageAccumulator()

                    for (index, chunk) in chunks.enumerated() {
                        let chunkContext = TrackSummaryPromptContext(
                            trackTitle: context.trackTitle,
                            trackDuration: context.trackDuration,
                            trackAuthor: context.trackAuthor,
                            collectionTitle: context.collectionTitle,
                            collectionDescription: context.collectionDescription,
                            transcriptLanguage: context.transcriptLanguage,
                            segments: chunk,
                            targetSectionCount: context.targetSectionCount,
                            includeKeywords: context.includeKeywords,
                            requestTranslations: context.requestTranslations
                        )

                        let prompts = trackSummaryGenerator.makePrompts(from: chunkContext)
                        logger.info("[TrackSummaryTranslationOnly] Input (chunk \(index + 1)/\(chunks.count)): \(prompts.userPrompt, privacy: .public)")

                        setInitialStreamBuffer("", reasoning: "", for: job.id)

                        let response = try await gatewayClient.sendChat(
                            apiKey: apiKey,
                            model: modelId,
                            systemPrompt: prompts.systemPrompt,
                            userPrompt: prompts.userPrompt,
                            temperature: 0.3,
                            onStreamDelta: onDelta
                        )

                        let rawText = response.choices.first?.message.content ?? currentContentBuffer(for: job.id)
                        try await dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: rawText)
                        logger.info("[TrackSummaryTranslationOnly] Output (chunk \(index + 1)/\(chunks.count)): \(rawText, privacy: .public)")

                        if let snapshot = reasoningSnapshot(from: response.choices.first?.message) {
                            metadata = metadata.updatingReasoning(snapshot)
                        }

                        let chunkParsed = try trackSummaryGenerator.parseTranslationOnlyResponse(rawText, segments: chunk)
                        if firstChunkResult == nil {
                            firstChunkResult = chunkParsed
                        }
                        chunkTranslations.append(contentsOf: chunkParsed.translations)

                        accumulatedUsage.merge(response.usage)

                        let progress = 0.2 + (0.6 * Double(index + 1) / Double(chunks.count))
                        try await dbManager.updateAIGenerationJobStatus(jobId: job.id, status: .streaming, progress: progress)
                    }

                    guard let result = firstChunkResult else {
                        throw AIGatewayRequestError(message: "Translation request returned no output.")
                    }

                    parsed = result
                    translations = chunkTranslations
                        .sorted { $0.startTimeMs < $1.startTimeMs }
                        .enumerated()
                        .map { index, payload in
                            TrackSummaryTranslation(
                                orderIndex: index,
                                startTimeMs: payload.startTimeMs,
                                translation: payload.translation
                            )
                        }
                    usageSnapshot = accumulatedUsage.snapshot
                } else {
                    let prompts = trackSummaryGenerator.makePrompts(from: context)
                    let response = try await gatewayClient.sendChat(
                        apiKey: apiKey,
                        model: modelId,
                        systemPrompt: prompts.systemPrompt,
                        userPrompt: prompts.userPrompt,
                        temperature: 0.3,
                        onStreamDelta: onDelta
                    )

                    let rawText = response.choices.first?.message.content ?? currentContentBuffer(for: job.id)
                    try await dbManager.updateAIGenerationJobStream(jobId: job.id, streamedOutput: rawText)

                    if let snapshot = reasoningSnapshot(from: response.choices.first?.message) {
                        metadata = metadata.updatingReasoning(snapshot)
                    }

                    parsed = try trackSummaryGenerator.parseResponse(rawText)
                    translations = parsed.translations.enumerated().map { index, payload in
                        TrackSummaryTranslation(
                            orderIndex: index,
                            startTimeMs: payload.startTimeMs,
                            translation: payload.translation
                        )
                    }
                    if let usage = response.usage {
                        usageSnapshot = AIGenerationUsageSnapshot(
                            promptTokens: usage.promptTokens,
                            completionTokens: usage.completionTokens,
                            totalTokens: usage.totalTokens,
                            cost: usage.cost,
                            reasoningTokens: usage.completionTokensDetails?.reasoningTokens
                        )
                    }
                }
            }

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
                mentionedItems: parsed.mentionedItems,
                suggestedCorrections: parsed.suggestedCorrections,
                translations: translations,
                sections: sections,
                modelIdentifier: modelId,
                jobId: job.id,
                translationOnly: payload.translationOnly
            )

            if let json = encodeMetadata(metadata) {
                try await dbManager.updateAIGenerationJobMetadata(jobId: job.id, metadataJSON: json)
            }

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
                jobId: job.id,
                translationOnly: payload.translationOnly
            )
            throw error
        }
    }

    // MARK: - Helpers

    private func loadRemoteJobsConfig() throws -> RemoteJobsConfig {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "remoteJobsEnabled") else {
            throw AIGatewayRequestError(message: "Remote jobs are not configured.")
        }
        let baseURLString = (defaults.string(forKey: "remoteJobsBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil else {
            throw AIGatewayRequestError(message: "Remote jobs are not configured.")
        }
        let token = defaults.string(forKey: "remoteJobsAuthToken")
        return RemoteJobsConfig(baseURL: baseURL, token: token)
    }

    private func persistRemoteJobId(
        _ remoteJobId: String,
        jobId: String,
        metadata: inout AIGenerationJobMetadata
    ) async throws {
        metadata = metadata.updatingExtra(remoteJobMetadataKey, value: remoteJobId)
        if let json = encodeMetadata(metadata) {
            try await dbManager.updateAIGenerationJobMetadata(jobId: jobId, metadataJSON: json)
        }
    }

    private func pollRemoteAIJob(
        client: RemoteJobsClient,
        remoteJob: RemoteJobDTO,
        jobId: String,
        progressRange: ClosedRange<Double>
    ) async throws -> String {
        let startTime = Date()
        var latestStatus = remoteJob
        var lastProgress = progressRange.lowerBound

        while latestStatus.status == "queued" || latestStatus.status == "running" {
            let mapped = mapRemoteProgress(
                latestStatus.progress,
                range: progressRange,
                floor: lastProgress
            )
            if mapped > lastProgress {
                lastProgress = mapped
                try await dbManager.updateAIGenerationJobStatus(
                    jobId: jobId,
                    status: .running,
                    progress: mapped
                )
            }

            if Date().timeIntervalSince(startTime) > remoteMaxPollingDuration {
                throw AIGatewayRequestError(message: "Remote AI job timed out.")
            }

            try await Task.sleep(nanoseconds: UInt64(remotePollingInterval * 1_000_000_000))
            latestStatus = try await client.fetchJob(jobId: remoteJob.id)
        }

        guard latestStatus.status == "succeeded" else {
            throw AIGatewayRequestError(message: "Remote job \(latestStatus.status)")
        }

        if lastProgress < progressRange.upperBound {
            try await dbManager.updateAIGenerationJobStatus(
                jobId: jobId,
                status: .running,
                progress: progressRange.upperBound
            )
        }

        let result = try await client.fetchAIResult(jobId: remoteJob.id)
        return result.text
    }

    private func mapRemoteProgress(
        _ progress: Double?,
        range: ClosedRange<Double>,
        floor: Double
    ) -> Double {
        let raw = max(0.0, min(progress ?? 0.0, 1.0))
        let mapped = range.lowerBound + raw * (range.upperBound - range.lowerBound)
        return max(floor, min(mapped, range.upperBound))
    }

    private func reasoningSnapshot(from message: AIGatewayChatChoice.ChoiceMessage?) -> AIGenerationReasoningSnapshot? {
        guard let message else { return nil }
        let hasText = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasDetails = !(message.reasoningDetails?.isEmpty ?? true)
        guard hasText || hasDetails else { return nil }
        return AIGenerationReasoningSnapshot(text: message.reasoning, details: message.reasoningDetails)
    }

    nonisolated private func encodeMetadata(_ metadata: AIGenerationJobMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private func encodeUsage(_ usage: AIGenerationUsageSnapshot?) -> String? {
        guard let usage else { return nil }
        guard let data = try? JSONEncoder().encode(usage) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func setInitialStreamBuffer(_ initialContent: String, reasoning: String, for jobId: String) {
        streamBuffers[jobId] = StreamBuffer(content: initialContent, reasoning: reasoning)
    }

    private func currentContentBuffer(for jobId: String) -> String {
        streamBuffers[jobId]?.content ?? ""
    }

    private func clearStreamBuffer(for jobId: String) {
        streamBuffers[jobId] = nil
    }

    private func persistStreamDelta(_ delta: AIGatewayClient.StreamDelta, for jobId: String) async {
        var buffer = streamBuffers[jobId] ?? StreamBuffer(content: "", reasoning: "")
        
        switch delta {
        case .content(let text):
            buffer.content.append(text)
        case .reasoning(let text):
            buffer.reasoning.append(text)
        }
        
        streamBuffers[jobId] = buffer
        
        do {
            try await dbManager.updateAIGenerationJobStream(
                jobId: jobId,
                streamedOutput: buffer.content,
                streamedReasoning: buffer.reasoning
            )
        } catch {
            logger.error("Failed updating stream buffer for job \(jobId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension AIGenerationJobExecutor {
    func filterTranslationSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments
            .filter { segment in
                let sanitized = segment.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !sanitized.isEmpty
            }
            .sorted { $0.startTimeMs < $1.startTimeMs }
    }
}

private struct UsageAccumulator {
    private(set) var promptTokens: Int = 0
    private(set) var completionTokens: Int = 0
    private(set) var totalTokens: Int = 0
    private(set) var cost: Double = 0
    private(set) var reasoningTokens: Int = 0
    private var hasData = false

    mutating func merge(_ usage: ChatCompletionsResponse.Usage?) {
        guard let usage else { return }
        promptTokens += usage.promptTokens ?? 0
        completionTokens += usage.completionTokens ?? 0
        totalTokens += usage.totalTokens ?? 0
        cost += usage.cost ?? 0
        reasoningTokens += usage.completionTokensDetails?.reasoningTokens ?? 0
        hasData = true
    }

    var snapshot: AIGenerationUsageSnapshot? {
        guard hasData else { return nil }
        return AIGenerationUsageSnapshot(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cost: cost,
            reasoningTokens: reasoningTokens
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
