import Foundation

// MARK: - Chat API Protocol

enum ChatAPIProtocol: String {
    case chatCompletions   // POST /chat/completions  (OpenAI-compatible)
    case anthropicMessages // POST /messages          (Anthropic Messages API)
    case openAIResponses   // POST /responses         (OpenAI Responses API)

    var displayName: String {
        switch self {
        case .chatCompletions:   return "Chat Completions"
        case .anthropicMessages: return "Messages"
        case .openAIResponses:   return "Responses"
        }
    }
}

// MARK: - AIModelCatalog

enum AIModelCatalog {

    /// Known provider prefixes for bare model IDs (no `/` separator).
    /// Order matters only for deterministic matching; first match wins.
    private static let knownProviderPrefixes: [String] = [
        "minimax", "kimi", "glm", "deepseek", "qwen", "mimo", "hy3", "gpt", "grok"
    ]

    // MARK: - Provider grouping

    /// Returns a stable provider key used for UI grouping.
    /// For prefixed IDs like `openai/gpt-4o` the prefix is returned directly.
    /// For bare IDs like `minimax-m3` the provider is inferred from known prefixes.
    static func groupingProviderKey(for modelID: String) -> String {
        // Prefixed id → use prefix
        if let slash = modelID.firstIndex(of: "/") {
            let prefix = String(modelID[modelID.startIndex..<slash])
            return prefix.isEmpty ? otherGroupKey : prefix
        }

        // Bare id → infer from known prefixes
        let lower = modelID.lowercased()
        for prefix in knownProviderPrefixes {
            if lower.hasPrefix(prefix) {
                return prefix
            }
        }

        return otherGroupKey
    }

    private static let otherGroupKey: String = NSLocalizedString("ai_tab_model_group_other", comment: "")

    // MARK: - Model ID resolution (strip prefix for OpenCode/custom)

    /// Strips the provider prefix from a model ID when targeting OpenCode Go or custom
    /// endpoints. Vercel AI Gateway and other endpoints keep the full prefixed ID.
    ///
    /// Examples:
    ///   `openai/gpt-4o` → `gpt-4o`   (OpenCode/custom)
    ///   `openai/gpt-4o` → `openai/gpt-4o` (Vercel)
    ///   `minimax-m3`    → `minimax-m3` (bare, unchanged)
    static func resolvedModelID(_ modelID: String, endpoint: AIGatewayEndpointPreset) -> String {
        switch endpoint {
        case .opencodeGo, .custom:
            if let slash = modelID.firstIndex(of: "/") {
                return String(modelID[modelID.index(after: slash)...])
            }
            return modelID
        case .vercelAIGateway:
            return modelID
        }
    }

    // MARK: - Protocol auto-selection

    /// Auto-selects the chat API protocol for the given model on OpenCode/custom endpoints.
    /// Vercel AI Gateway always uses `chatCompletions`.
    ///
    /// Rules:
    ///   - `gpt-5.6-luna` → `.openAIResponses`
    ///   - `minimax*` / `qwen*` → `.anthropicMessages`
    ///   - everything else → `.chatCompletions`
    static func chatAPIProtocol(model: String, endpoint: AIGatewayEndpointPreset) -> ChatAPIProtocol {
        // Vercel always uses chat/completions
        guard endpoint == .opencodeGo || endpoint == .custom else {
            return .chatCompletions
        }

        let bare = resolvedModelID(model, endpoint: endpoint).lowercased()

        if bare == "gpt-5.6-luna" || bare.hasPrefix("gpt-5.6") {
            return .openAIResponses
        }

        if bare.hasPrefix("minimax") || bare.hasPrefix("qwen") {
            return .anthropicMessages
        }

        return .chatCompletions
    }
}
