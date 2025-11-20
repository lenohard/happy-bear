import Foundation

struct AIGatewayRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class AIGatewayClient {
    private let baseURL = URL(string: "https://ai-gateway.vercel.sh/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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

    func sendChat(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.7,
        reasoning: AIGatewayReasoningConfig? = nil,
        onStreamDelta: ((String) -> Void)? = nil,
        onStreamFallback: (() -> Void)? = nil
    ) async throws -> ChatCompletionsResponse {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "stream": true
        ]

        if let reasoning {
            payload["reasoning"] = try encodeReasoningPayload(reasoning)
        }

        do {
            return try await streamChatCompletion(apiKey: apiKey, payload: payload, onDelta: onStreamDelta)
        } catch {
            if let urlError = error as? URLError, urlError.code == .secureConnectionFailed {
                payload["stream"] = false
                onStreamFallback?()
                let fallback: ChatCompletionsResponse = try await request(
                    endpoint: "chat/completions",
                    method: "POST",
                    apiKey: apiKey,
                    jsonBody: payload
                )
                if let final = fallback.choices.first?.message.content, !final.isEmpty {
                    onStreamDelta?(final)
                }
                return fallback
            }
            throw error
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

    private func streamChatCompletion(
        apiKey: String,
        payload: [String: Any],
        onDelta: ((String) -> Void)? = nil
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
                    onDelta?(content)
                }
                if let reasoning = choice.delta?.reasoning {
                    accumulatedReasoning.append(reasoning)
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
