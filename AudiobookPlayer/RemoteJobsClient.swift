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
    struct Input: Decodable {
        let kind: String?
        let text: String?
        let mime: String?
        let url: String?
        let source: String?
    }

    struct ErrorPayload: Decodable {
        let code: String?
        let message: String?
    }

    let id: String
    let type: String
    let status: String
    let progress: Double?
    let createdAt: String?
    let title: String?
    let subtype: String?
    let input: Input?
    let error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case progress
        case createdAt = "created_at"
        case title
        case subtype
        case input
        case error
    }
}

struct RemoteJobsPage {
    let jobs: [RemoteJobDTO]
    let nextCursor: String?
}

enum RemoteJobResultDTO {
    struct STTResult: Decodable {
        let format: String
        let srt: String?
        let transcript: String?
    }

    struct AIResult: Decodable {
        let text: String
    }
}

final class RemoteJobsClient {
    private let config: RemoteJobsConfig
    private let decoder = JSONDecoder()

    init(config: RemoteJobsConfig) {
        self.config = config
    }

    func createSTTJob(input: RemoteJobsInput, languageHints: [String], context: String?, dedupKey: String? = nil) async throws -> RemoteJobDTO {
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
            let dedup_key: String?
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
            params: .init(language_hints: languageHints, context: context),
            dedup_key: dedupKey
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

    func fetchJobs(limit: Int = 100, status: String? = nil, cursor: String? = nil) async throws -> RemoteJobsPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let status, !status.isEmpty {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }

        var components = URLComponents()
        components.queryItems = queryItems
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let request = try makeRequest(path: "/jobs\(query)", method: "GET", body: Optional<String>.none)
        let response: RemoteJobsEnvelope = try await perform(request)
        return RemoteJobsPage(jobs: response.data.jobs, nextCursor: response.data.nextCursor)
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
        temperature: Double?,
        title: String? = nil,
        subtype: String? = nil,
        dedupKey: String? = nil
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
                let extra: [String: String]?
            }
            let type: String
            let input: Input
            let params: Params?
            let dedup_key: String?
        }

        let extra: [String: String]? = {
            var values: [String: String] = [:]
            if let title, !title.isEmpty {
                values["title"] = title
            }
            if let subtype, !subtype.isEmpty {
                values["subtype"] = subtype
            }
            return values.isEmpty ? nil : values
        }()

        let params: RequestBody.Params?
        if modelId != nil || systemPrompt != nil || temperature != nil || extra != nil {
            params = RequestBody.Params(model: modelId, system_prompt: systemPrompt, temperature: temperature, extra: extra)
        } else {
            params = nil
        }

        let body = RequestBody(
            type: "ai",
            input: .init(kind: "text", text: inputText),
            params: params,
            dedup_key: dedupKey
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

    func retryJob(jobId: String) async throws -> RemoteJobDTO {
        let request = try makeRequest(path: "/jobs/\(jobId)/retry", method: "POST", body: Optional<String>.none)
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
        let normalizedBase = normalizedBaseURLString()
        let versionedBase = normalizedBase.hasSuffix("/v1") ? normalizedBase : "\(normalizedBase)/v1"
        return URL(string: versionedBase + path)
    }

    private func normalizedBaseURLString() -> String {
        var base = config.baseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }

        // Accept user-provided URLs ending with /v1/jobs or /jobs and normalize them.
        if base.hasSuffix("/v1/jobs") {
            base.removeLast("/jobs".count)
        } else if base.hasSuffix("/jobs") {
            base.removeLast("/jobs".count)
        }

        return base
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

    private struct RemoteJobsEnvelope: Decodable {
        struct DataPayload: Decodable {
            let jobs: [RemoteJobDTO]
            let nextCursor: String?

            enum CodingKeys: String, CodingKey {
                case jobs
                case nextCursor = "next_cursor"
            }
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
