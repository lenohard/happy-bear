import Foundation

struct RemoteJobsConfig {
    let baseURL: URL
    let token: String?
}

enum RemoteJobsClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Remote jobs base URL is invalid."
        case .invalidResponse:
            return "Remote jobs server returned an invalid response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct RemoteJobsInput {
    let url: URL
    let source: String
    let cookie: String?
    let mime: String?
}

struct RemoteJobDTO: Decodable {
    let id: String
    let type: String
    let status: String
    let progress: Double?
}

struct RemoteJobResultDTO: Decodable {
    struct STTResult: Decodable {
        let format: String
        let srt: String?
        let transcript: String?
    }

    struct AIResult: Decodable {
        let text: String
    }

    let result: STTResult
}

final class RemoteJobsClient {
    private let config: RemoteJobsConfig
    private let decoder = JSONDecoder()

    init(config: RemoteJobsConfig) {
        self.config = config
    }

    func createSTTJob(input: RemoteJobsInput, languageHints: [String], context: String?) async throws -> RemoteJobDTO {
        struct RequestBody: Encodable {
            struct Input: Encodable {
                let kind: String
                let url: String
                let source: String
                let cookie: String?
                let mime: String?
            }
            struct Params: Encodable {
                let language_hints: [String]
                let context: String?
            }
            let type: String
            let input: Input
            let params: Params
        }

        let body = RequestBody(
            type: "stt",
            input: .init(
                kind: "url",
                url: input.url.absoluteString,
                source: input.source,
                cookie: input.cookie,
                mime: input.mime
            ),
            params: .init(language_hints: languageHints, context: context)
        )

        let request = try makeRequest(path: "/jobs", method: "POST", body: body)
        let response: RemoteJobEnvelope = try await perform(request)
        return response.data.job
    }

    func fetchJob(jobId: String) async throws -> RemoteJobDTO {
        let request = try makeRequest(path: "/jobs/\(jobId)", method: "GET", body: Optional<String>.none)
        let response: RemoteJobEnvelope = try await perform(request)
        return response.data.job
    }

    func fetchSTTResult(jobId: String) async throws -> RemoteJobResultDTO.STTResult {
        let request = try makeRequest(path: "/jobs/\(jobId)/result", method: "GET", body: Optional<String>.none)
        let response: RemoteResultEnvelope = try await perform(request)
        return response.data.result
    }

    func createAIJob(
        inputText: String,
        modelId: String?,
        systemPrompt: String?,
        temperature: Double?
    ) async throws -> RemoteJobDTO {
        struct RequestBody: Encodable {
            struct Input: Encodable {
                let kind: String
                let text: String
            }
            struct Params: Encodable {
                let model: String?
                let system_prompt: String?
                let temperature: Double?
            }
            let type: String
            let input: Input
            let params: Params?
        }

        let params: RequestBody.Params?
        if modelId != nil || systemPrompt != nil || temperature != nil {
            params = RequestBody.Params(model: modelId, system_prompt: systemPrompt, temperature: temperature)
        } else {
            params = nil
        }

        let body = RequestBody(
            type: "ai",
            input: .init(kind: "text", text: inputText),
            params: params
        )

        let request = try makeRequest(path: "/jobs", method: "POST", body: body)
        let response: RemoteJobEnvelope = try await perform(request)
        return response.data.job
    }

    func fetchAIResult(jobId: String) async throws -> RemoteJobResultDTO.AIResult {
        let request = try makeRequest(path: "/jobs/\(jobId)/result", method: "GET", body: Optional<String>.none)
        let response: RemoteAIResultEnvelope = try await perform(request)
        return response.data.result
    }

    func cancelJob(jobId: String) async throws -> RemoteJobDTO {
        let request = try makeRequest(path: "/jobs/\(jobId)/cancel", method: "POST", body: Optional<String>.none)
        let response: RemoteJobEnvelope = try await perform(request)
        return response.data.job
    }

    func deleteJob(jobId: String) async throws {
        struct DeleteResponse: Decodable {
            struct DataPayload: Decodable { let deleted: Bool }
            let data: DataPayload
        }
        let request = try makeRequest(path: "/jobs/\(jobId)", method: "DELETE", body: Optional<String>.none)
        let _: DeleteResponse = try await perform(request)
    }

    private func makeRequest<Body: Encodable>(path: String, method: String, body: Body?) throws -> URLRequest {
        guard let endpoint = makeEndpoint(path: path) else {
            throw RemoteJobsClientError.invalidBaseURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func makeEndpoint(path: String) -> URL? {
        let base = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = base.hasSuffix("/v1") ? base : "\(base)/v1"
        return URL(string: normalized + path)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteJobsClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw RemoteJobsClientError.requestFailed(message)
        }
        return try decoder.decode(Response.self, from: data)
    }

    private struct RemoteJobEnvelope: Decodable {
        struct DataPayload: Decodable {
            let job: RemoteJobDTO
        }
        let data: DataPayload
    }

    private struct RemoteResultEnvelope: Decodable {
        struct DataPayload: Decodable {
            let result: RemoteJobResultDTO.STTResult
        }
        let data: DataPayload
    }

    private struct RemoteAIResultEnvelope: Decodable {
        struct DataPayload: Decodable {
            let result: RemoteJobResultDTO.AIResult
        }
        let data: DataPayload
    }
}
