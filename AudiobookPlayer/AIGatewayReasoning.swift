import Foundation

enum AIGatewayReasoningEffort: String, Codable {
    case low
    case medium
    case high
}

struct AIGatewayReasoningConfig: Codable, Equatable {
    let enabled: Bool
    let maxTokens: Int?
    let effort: AIGatewayReasoningEffort?
    let exclude: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxTokens = "max_tokens"
        case effort
        case exclude
    }
}

struct AIGenerationReasoningSnapshot: Codable, Equatable {
    let text: String?
    let details: [AIGatewayReasoningDetail]?
}

struct AIGatewayReasoningDetail: Codable, Equatable {
    let type: String
    let text: String?
    let summary: String?
    let data: String?
    let signature: String?
    let format: String?
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case summary
        case data
        case signature
        case format
        case index
    }
}
