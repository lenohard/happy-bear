import Foundation

struct AIModelPricing: Codable {
    let input: String?
    let output: String?
    let inputCacheRead: String?

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case inputCacheRead = "input_cache_read"
    }
}

struct AIModelMetadata: Codable {
    let provider: String?
    let modality: [String]?
    let inputCost: Double?
    let outputCost: Double?

    enum CodingKeys: String, CodingKey {
        case provider
        case modality
        case inputCost = "input_cost"
        case outputCost = "output_cost"
    }
}

struct AIModelInfo: Identifiable, Codable {
    let id: String
    let name: String?
    let description: String?
    let ownedBy: String?
    let created: TimeInterval?
    let maxTokens: Int?
    let contextWindow: Int?
    let tags: [String]?
    let type: String?
    let pricing: AIModelPricing?
    let metadata: AIModelMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case ownedBy = "owned_by"
        case created
        case maxTokens = "max_tokens"
        case contextWindow = "context_window"
        case tags
        case type
        case pricing
        case metadata
    }
}

struct ModelsResponse: Codable {
    let data: [AIModelInfo]
}

struct CreditsResponse: Codable {
    let balance: String
    let totalUsed: String

    enum CodingKeys: String, CodingKey {
        case balance
        case totalUsed = "total_used"
    }
}

struct AIGatewayChatMessage: Codable {
    let role: String
    let content: String
}

struct AIGatewayChatChoice: Codable {
    struct ChoiceMessage: Codable {
        let role: String
        let content: String
        let reasoning: String?
        let reasoningDetails: [AIGatewayReasoningDetail]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoning
            case reasoningDetails = "reasoning_details"
        }
    }

    let index: Int
    let message: ChoiceMessage
}

struct ChatCompletionsResponse: Codable {
    let id: String
    let model: String
    let choices: [AIGatewayChatChoice]
    let usage: Usage?

    struct Usage: Codable {
        struct CompletionTokensDetails: Codable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?
        let marketCost: Double?
        let isByok: Bool?
        let completionTokensDetails: CompletionTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case cost
            case marketCost = "market_cost"
            case isByok = "is_byok"
            case completionTokensDetails = "completion_tokens_details"
        }
    }
}

struct GenerationResponse: Codable {
    let data: GenerationDetails
}

struct GenerationDetails: Codable {
    let id: String
    let totalCost: Double?
    let usage: Double?
    let createdAt: Date?
    let model: String?
    let isByok: Bool?
    let providerName: String?
    let streamed: Bool?
    let latency: Double?
    let generationTime: Double?
    let tokensPrompt: Int?
    let tokensCompletion: Int?
    let nativeTokensPrompt: Int?
    let nativeTokensCompletion: Int?
    let nativeTokensReasoning: Int?
    let nativeTokensCached: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case totalCost = "total_cost"
        case usage
        case createdAt = "created_at"
        case model
        case isByok = "is_byok"
        case providerName = "provider_name"
        case streamed
        case latency
        case generationTime = "generation_time"
        case tokensPrompt = "tokens_prompt"
        case tokensCompletion = "tokens_completion"
        case nativeTokensPrompt = "native_tokens_prompt"
        case nativeTokensCompletion = "native_tokens_completion"
        case nativeTokensReasoning = "native_tokens_reasoning"
        case nativeTokensCached = "native_tokens_cached"
    }
}
