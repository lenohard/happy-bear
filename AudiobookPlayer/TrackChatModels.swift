import Foundation

enum TrackChatMessageRole: String, Codable {
    case system
    case user
    case assistant
}

enum TrackChatTranscriptScope: String, Codable, CaseIterable {
    case auto
    case full
    case recent
}

struct TrackChatContextSelection: Codable, Equatable {
    var includeTrackInfo: Bool
    var includeCollectionInfo: Bool
    var includeTranscript: Bool
    var transcriptScope: TrackChatTranscriptScope
    var recentMinutes: Int?

    static func `default`(transcriptAvailable: Bool) -> TrackChatContextSelection {
        TrackChatContextSelection(
            includeTrackInfo: true,
            includeCollectionInfo: true,
            includeTranscript: transcriptAvailable,
            transcriptScope: .auto,
            recentMinutes: transcriptAvailable ? 10 : nil
        )
    }
}

struct TrackChatSession: Identifiable, Codable, Equatable {
    let id: String
    let trackId: String
    let collectionId: String?
    var title: String?
    var modelId: String?
    var contextSelection: TrackChatContextSelection
    var contextSnapshot: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        trackId: String,
        collectionId: String?,
        title: String? = nil,
        modelId: String? = nil,
        contextSelection: TrackChatContextSelection,
        contextSnapshot: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trackId = trackId
        self.collectionId = collectionId
        self.title = title
        self.modelId = modelId
        self.contextSelection = contextSelection
        self.contextSnapshot = contextSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct TrackChatUsage: Codable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?
}

struct TrackChatMessageMetadata: Codable, Equatable {
    var tokenCount: Int?
    var errorMessage: String?
    var reasoning: String?
    var reasoningDuration: TimeInterval?
    var usage: TrackChatUsage?
    var modelId: String?
}

struct TrackChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    var role: TrackChatMessageRole
    var content: String
    var metadata: TrackChatMessageMetadata?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        role: TrackChatMessageRole,
        content: String,
        metadata: TrackChatMessageMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
