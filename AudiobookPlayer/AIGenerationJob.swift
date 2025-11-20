import Foundation

/// Represents a background AI generation job (chat tester, transcript repair, summaries, etc.)
struct AIGenerationJob: Identifiable, Codable, Equatable {
    enum JobType: String, Codable {
        case chatTester = "chat_tester"
        case transcriptRepair = "transcript_repair"
        case trackSummary = "track_summary"
    }

    enum Status: String, Codable {
        case queued
        case running
        case streaming
        case completed
        case failed
        case canceled
    }

    let id: String
    let type: JobType
    var status: Status
    var modelId: String?
    var trackId: String?
    var transcriptId: String?
    var sourceContext: String?
    var displayName: String?
    var systemPrompt: String?
    var userPrompt: String?
    var payloadJSON: String?
    var metadataJSON: String?
    var streamedOutput: String?
    var finalOutput: String?
    var usageJSON: String?
    var progress: Double?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var retryCount: Int
    var lastAttemptAt: Date?

    init(
        id: String = UUID().uuidString,
        type: JobType,
        status: Status = .queued,
        modelId: String? = nil,
        trackId: String? = nil,
        transcriptId: String? = nil,
        sourceContext: String? = nil,
        displayName: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String? = nil,
        payloadJSON: String? = nil,
        metadataJSON: String? = nil,
        streamedOutput: String? = nil,
        finalOutput: String? = nil,
        usageJSON: String? = nil,
        progress: Double? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.modelId = modelId
        self.trackId = trackId
        self.transcriptId = transcriptId
        self.sourceContext = sourceContext
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.payloadJSON = payloadJSON
        self.metadataJSON = metadataJSON
        self.streamedOutput = streamedOutput
        self.finalOutput = finalOutput
        self.usageJSON = usageJSON
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .failed, .canceled:
            return true
        default:
            return false
        }
    }

    var isActive: Bool {
        switch status {
        case .queued, .running, .streaming:
            return true
        default:
            return false
        }
    }

    func updating(
        status: Status? = nil,
        metadataJSON: String? = nil,
        streamedOutput: String? = nil,
        finalOutput: String? = nil,
        usageJSON: String? = nil,
        progress: Double? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) -> AIGenerationJob {
        AIGenerationJob(
            id: id,
            type: type,
            status: status ?? self.status,
            modelId: modelId,
            trackId: trackId,
            transcriptId: transcriptId,
            sourceContext: sourceContext,
            displayName: displayName,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            payloadJSON: payloadJSON,
            metadataJSON: metadataJSON ?? self.metadataJSON,
            streamedOutput: streamedOutput ?? self.streamedOutput,
            finalOutput: finalOutput ?? self.finalOutput,
            usageJSON: usageJSON ?? self.usageJSON,
            progress: progress ?? self.progress,
            errorMessage: errorMessage ?? self.errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt ?? self.completedAt,
            retryCount: retryCount,
            lastAttemptAt: lastAttemptAt
        )
    }

    func decodedPayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let payloadJSON, let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func decodedUsage() -> AIGenerationUsageSnapshot? {
        guard let usageJSON, let data = usageJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIGenerationUsageSnapshot.self, from: data)
    }

    func decodedMetadata() -> AIGenerationJobMetadata? {
        guard let metadataJSON, let data = metadataJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIGenerationJobMetadata.self, from: data)
    }
}

struct AIGenerationUsageSnapshot: Codable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?
    let reasoningTokens: Int?
}

struct ChatTesterJobPayload: Codable, Equatable {
    let temperature: Double
    let reasoning: AIGatewayReasoningConfig?
}

struct TranscriptRepairJobPayload: Codable, Equatable {
    let transcriptId: String
    let trackTitle: String
    let collectionTitle: String?
    let collectionDescription: String?
    let selectionIndexes: [Int]
    let instructions: String?
}

struct TrackSummaryJobPayload: Codable, Equatable {
    let transcriptId: String
    let trackId: String
    let targetSectionCount: Int?
    let includeKeywords: Bool
}

struct AIGenerationJobMetadata: Codable, Equatable {
    var flags: [String: Bool]?
    var extras: [String: String]?
    var repairResults: [TranscriptRepairResult]?
    var reasoning: AIGenerationReasoningSnapshot?

    func flagEnabled(_ key: String) -> Bool {
        flags?[key] ?? false
    }

    func updatingFlag(_ key: String, value: Bool) -> AIGenerationJobMetadata {
        var copy = self
        var map = copy.flags ?? [:]
        map[key] = value
        copy.flags = map
        return copy
    }

    func updatingRepairResults(_ results: [TranscriptRepairResult]) -> AIGenerationJobMetadata {
        var copy = self
        copy.repairResults = results
        return copy
    }

    func updatingReasoning(_ snapshot: AIGenerationReasoningSnapshot?) -> AIGenerationJobMetadata {
        var copy = self
        copy.reasoning = snapshot
        return copy
    }
}
