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
        maxTokens: Int = 256,
        temperature: Double = 0.7
    ) async throws -> ChatCompletionsResponse {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        return try await request(endpoint: "chat/completions", method: "POST", apiKey: apiKey, jsonBody: payload)
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
}
