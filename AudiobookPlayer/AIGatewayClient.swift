import Foundation

struct AIGatewayRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class AIGatewayClient {
    private let baseURL: URL
    private let session: URLSession
    let endpointPreset: AIGatewayEndpointPreset

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 360
        configuration.timeoutIntervalForResource = 1200
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL? = nil, endpointPreset: AIGatewayEndpointPreset = .opencodeGo, session: URLSession = AIGatewayClient.defaultSession) {
        self.baseURL = baseURL ?? Self.resolveConfiguredBaseURL() ?? URL(string: "https://opencode.ai/zen/go/v1")!
        self.endpointPreset = endpointPreset
        self.session = session
    }

    private static func resolveConfiguredBaseURL() -> URL? {
        let endpointConfigKey = "ai_gateway_endpoint_config"
        guard let data = UserDefaults.standard.data(forKey: endpointConfigKey),
              let config = try? JSONDecoder().decode(AIGatewayEndpointConfig.self, from: data),
              !config.baseURL.isEmpty,
              let url = URL(string: config.baseURL) else {
            return nil
        }
        return url
    }

    func fetchModels(apiKey: String) async throws -> [AIModelInfo] {
        let response: ModelsResponse = try await request(endpoint: "models", method: "GET", apiKey: apiKey)
        return response.data.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    func fetchModelDetail(apiKey: String, id: String) async throws -> AIModelInfo {
        try await request(endpoint: "models/\(id)", method: "GET", apiKey: apiKey)
    }

    func fetchCredits(apiKey: String) async throws -> CreditsResponse {
        try await request(endpoint: "credits", method: "GET", apiKey: apiKey)
    }

    func fetchGeneration(apiKey: String, id: String) async throws -> GenerationResponse {
        let query = URLQueryItem(name: "id", value: id)
        return try await request(endpoint: "generation", method: "GET", apiKey: apiKey, queryItems: [query])
    }

    enum StreamDelta {
        case content(String)
        case reasoning(String)
    }

    func sendChat(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.7,
        reasoning: AIGatewayReasoningConfig? = nil,
        onStreamDelta: ((StreamDelta) -> Void)? = nil,
        onStreamFallback: (() -> Void)? = nil
    ) async throws -> ChatCompletionsResponse {
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        return try await sendChatMessages(
            apiKey: apiKey,
            model: model,
            messages: messages,
            temperature: temperature,
            reasoning: reasoning,
            onStreamDelta: onStreamDelta,
            onStreamFallback: onStreamFallback
        )
    }

    func sendChatMessages(
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        temperature: Double = 0.7,
        reasoning: AIGatewayReasoningConfig? = nil,
        onStreamDelta: ((StreamDelta) -> Void)? = nil,
        onStreamFallback: (() -> Void)? = nil
    ) async throws -> ChatCompletionsResponse {
        let protocol_ = AIModelCatalog.chatAPIProtocol(model: model, endpoint: endpointPreset)
        let resolvedModel = AIModelCatalog.resolvedModelID(model, endpoint: endpointPreset)

        switch protocol_ {
        case .anthropicMessages:
            return try await streamAnthropicMessages(
                apiKey: apiKey, model: resolvedModel, messages: messages,
                temperature: temperature, onDelta: onStreamDelta
            )
        case .openAIResponses:
            return try await streamOpenAIResponses(
                apiKey: apiKey, model: resolvedModel, messages: messages,
                temperature: temperature, onDelta: onStreamDelta
            )
        case .chatCompletions:
            var payload: [String: Any] = [
                "model": resolvedModel,
                "messages": messages,
                "temperature": temperature,
                "stream": true
            ]
            if let reasoning {
                payload["reasoning"] = try encodeReasoningPayload(reasoning)
            }
            return try await streamChatCompletion(apiKey: apiKey, payload: payload, onDelta: onStreamDelta)
        }
    }

    private struct ChatStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let role: String?
                let content: String?
                let reasoning: String?
                let reasoningDetails: [AIGatewayReasoningDetail]?
            }

            let index: Int
            let delta: Delta?
        }

        let id: String
        let model: String
        let choices: [Choice]
        let usage: ChatCompletionsResponse.Usage?
    }

    // MARK: - Anthropic Messages Protocol

    private func streamAnthropicMessages(
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        onDelta: ((StreamDelta) -> Void)?
    ) async throws -> ChatCompletionsResponse {
        // Extract system message; remaining messages become the messages array
        var systemText: String?
        var apiMessages: [[String: Any]] = []
        for msg in messages {
            if (msg["role"] as? String) == "system" {
                systemText = msg["content"] as? String
            } else {
                apiMessages.append(msg)
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": 8192,
            "temperature": temperature,
            "stream": true
        ]
        if let systemText, !systemText.isEmpty {
            payload["system"] = systemText
        }

        let url = baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIGatewayRequestError(message: "Invalid server response.")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            var body = Data()
            for try await chunk in bytes { body.append(chunk) }
            let msg = String(data: body, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
            throw AIGatewayRequestError(message: msg)
        }

        var accumulatedText = ""
        var accumulatedReasoning = ""
        var responseID = ""
        var responseModel = model
        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payloadString = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payloadString.isEmpty, payloadString != "[DONE]" else { continue }
            guard let data = payloadString.data(using: .utf8) else { continue }

            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any] {
                    responseID = message["id"] as? String ?? ""
                    responseModel = message["model"] as? String ?? model
                    if let usage = message["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int ?? 0
                    }
                }

            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String ?? ""
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        accumulatedText.append(text)
                        onDelta?(.content(text))
                    } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                        accumulatedReasoning.append(thinking)
                        onDelta?(.reasoning(thinking))
                    }
                }

            case "message_delta":
                if let usage = event["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            default:
                break
            }
        }

        let message = AIGatewayChatChoice.ChoiceMessage(
            role: "assistant",
            content: accumulatedText,
            reasoning: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning,
            reasoningDetails: nil
        )
        let choice = AIGatewayChatChoice(index: 0, message: message)
        let usage = ChatCompletionsResponse.Usage(
            promptTokens: inputTokens,
            completionTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            cost: nil, marketCost: nil, isByok: nil, completionTokensDetails: nil
        )
        return ChatCompletionsResponse(id: responseID, model: responseModel, choices: [choice], usage: usage)
    }

    // MARK: - OpenAI Responses Protocol

    private func streamOpenAIResponses(
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        onDelta: ((StreamDelta) -> Void)?
    ) async throws -> ChatCompletionsResponse {
        // Extract system message → instructions; remaining → input
        var instructions: String?
        var inputItems: [[String: Any]] = []
        for msg in messages {
            if (msg["role"] as? String) == "system" {
                instructions = msg["content"] as? String
            } else {
                inputItems.append(msg)
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "input": inputItems,
            "stream": true,
            "temperature": temperature
        ]
        if let instructions, !instructions.isEmpty {
            payload["instructions"] = instructions
        }

        let url = baseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIGatewayRequestError(message: "Invalid server response.")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            var body = Data()
            for try await chunk in bytes { body.append(chunk) }
            let msg = String(data: body, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
            throw AIGatewayRequestError(message: msg)
        }

        var accumulatedText = ""
        var responseID = ""
        var responseModel = model
        var usage: ChatCompletionsResponse.Usage?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payloadString = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payloadString.isEmpty, payloadString != "[DONE]" else { continue }
            guard let data = payloadString.data(using: .utf8) else { continue }

            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""

            switch type {
            case "response.created":
                if let resp = event["response"] as? [String: Any] {
                    responseID = resp["id"] as? String ?? ""
                    responseModel = resp["model"] as? String ?? model
                }

            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    accumulatedText.append(delta)
                    onDelta?(.content(delta))
                }

            case "response.completed":
                if let resp = event["response"] as? [String: Any],
                   let usageDict = resp["usage"] as? [String: Any] {
                    let promptTokens = usageDict["input_tokens"] as? Int ?? usageDict["prompt_tokens"] as? Int
                    let completionTokens = usageDict["output_tokens"] as? Int ?? usageDict["completion_tokens"] as? Int
                    let total = (promptTokens ?? 0) + (completionTokens ?? 0)
                    usage = ChatCompletionsResponse.Usage(
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        totalTokens: total,
                        cost: nil, marketCost: nil, isByok: nil, completionTokensDetails: nil
                    )
                }

            default:
                break
            }
        }

        let message = AIGatewayChatChoice.ChoiceMessage(
            role: "assistant",
            content: accumulatedText,
            reasoning: nil,
            reasoningDetails: nil
        )
        let choice = AIGatewayChatChoice(index: 0, message: message)
        return ChatCompletionsResponse(id: responseID, model: responseModel, choices: [choice], usage: usage)
    }

    // MARK: - Chat Completions Protocol

    private func streamChatCompletion(
        apiKey: String,
        payload: [String: Any],
        onDelta: ((StreamDelta) -> Void)? = nil
    ) async throws -> ChatCompletionsResponse {
        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIGatewayRequestError(message: "Invalid server response.")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            var body = Data()
            for try await chunk in bytes {
                body.append(chunk)
            }
            let message = String(data: body, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
            throw AIGatewayRequestError(message: message)
        }

        var accumulatedText = ""
        var detectedRole = "assistant"
        var responseID: String?
        var responseModel: String?
        var usage: ChatCompletionsResponse.Usage?
        var accumulatedReasoning = ""
        var accumulatedReasoningDetails: [AIGatewayReasoningDetail] = []
        var lastChoiceIndex = 0
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payloadString = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payloadString.isEmpty else { continue }
            if payloadString == "[DONE]" { break }
            guard let data = payloadString.data(using: .utf8) else { continue }

            let chunk = try decoder.decode(ChatStreamChunk.self, from: data)
            responseID = chunk.id
            responseModel = chunk.model
            if let chunkUsage = chunk.usage {
                usage = chunkUsage
            }

            for choice in chunk.choices {
                if let role = choice.delta?.role {
                    detectedRole = role
                }
                if let content = choice.delta?.content {
                    accumulatedText.append(content)
                    onDelta?(.content(content))
                }
                if let reasoning = choice.delta?.reasoning {
                    accumulatedReasoning.append(reasoning)
                    onDelta?(.reasoning(reasoning))
                }
                if let details = choice.delta?.reasoningDetails {
                    accumulatedReasoningDetails.append(contentsOf: details)
                }
                lastChoiceIndex = max(lastChoiceIndex, choice.index)
            }
        }

        guard let responseID, let responseModel else {
            throw AIGatewayRequestError(message: "Streaming response missing metadata.")
        }

        let message = AIGatewayChatChoice.ChoiceMessage(
            role: detectedRole,
            content: accumulatedText,
            reasoning: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning,
            reasoningDetails: accumulatedReasoningDetails.isEmpty ? nil : accumulatedReasoningDetails
        )
        let choice = AIGatewayChatChoice(index: lastChoiceIndex, message: message)

        return ChatCompletionsResponse(id: responseID, model: responseModel, choices: [choice], usage: usage)
    }

    private func request<T: Decodable>(
        endpoint: String,
        method: String,
        apiKey: String,
        queryItems: [URLQueryItem]? = nil,
        jsonBody: [String: Any]? = nil
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            throw AIGatewayRequestError(message: "Invalid endpoint: \(endpoint)")
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AIGatewayRequestError(message: "Invalid URL components for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIGatewayRequestError(message: "Invalid server response.")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
            throw AIGatewayRequestError(message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func encodeReasoningPayload(_ config: AIGatewayReasoningConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw AIGatewayRequestError(message: "Reasoning config could not be serialized.")
        }
        return dictionary
    }
}
