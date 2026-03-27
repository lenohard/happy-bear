import Combine
import Foundation

enum RemoteJobsConnectionStatus: String {
    case idle
    case testing
    case connected
    case authFailed
    case unreachable
    case invalidURL
}

struct RemoteJobsConnectionState: Equatable {
    var status: RemoteJobsConnectionStatus = .idle
    var latencyMs: Int?
    var message: String?
}

enum RemoteJobType: String, CaseIterable {
    case stt
    case tts
    case ai
}

enum RemoteJobStatus: String, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case canceled
}

struct RemoteJob: Identifiable, Hashable {
    let id: String
    var type: RemoteJobType
    var status: RemoteJobStatus
    var title: String
    var progress: Double
    var createdAt: Date
}

extension RemoteJobType {
    var badgeLabel: String {
        switch self {
        case .stt:
            return "STT"
        case .tts:
            return "TTS"
        case .ai:
            return "AI"
        }
    }
}

@MainActor
final class RemoteJobsStore: ObservableObject {
    @Published var connectionState = RemoteJobsConnectionState()
    @Published var jobs: [RemoteJob] = []

    func testConnection(baseURL: String, token: String?) async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = makeTestURL(from: trimmed) else {
            connectionState = RemoteJobsConnectionState(status: .invalidURL)
            return
        }

        connectionState = RemoteJobsConnectionState(status: .testing)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    connectionState = RemoteJobsConnectionState(status: .connected, latencyMs: latencyMs)
                case 401, 403:
                    connectionState = RemoteJobsConnectionState(status: .authFailed, latencyMs: latencyMs)
                default:
                    connectionState = RemoteJobsConnectionState(status: .unreachable, latencyMs: latencyMs, message: "HTTP \(httpResponse.statusCode)")
                }
            } else {
                connectionState = RemoteJobsConnectionState(status: .unreachable, latencyMs: latencyMs, message: "No HTTP response")
            }
        } catch {
            connectionState = RemoteJobsConnectionState(status: .unreachable, message: error.localizedDescription)
        }
    }

    private func makeTestURL(from baseURL: String) -> URL? {
        let normalized = normalizeBaseURLString(baseURL)
        guard URL(string: normalized)?.scheme != nil else {
            return nil
        }

        let versioned = normalized.hasSuffix("/v1") ? normalized : "\(normalized)/v1"
        return URL(string: "\(versioned)/jobs?limit=1")
    }

    func cancelJob(jobId: String, baseURL: String, token: String?) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        let client = RemoteJobsClient(config: config)
        _ = try await client.cancelJob(jobId: jobId)
    }

    func deleteJob(jobId: String, baseURL: String, token: String?) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        let client = RemoteJobsClient(config: config)
        try await client.deleteJob(jobId: jobId)
    }

    private func makeConfig(baseURL: String, token: String?) -> RemoteJobsConfig? {
        let normalized = normalizeBaseURLString(baseURL)
        guard let url = URL(string: normalized), url.scheme != nil else { return nil }
        return RemoteJobsConfig(baseURL: url, token: token)
    }

    private func normalizeBaseURLString(_ raw: String) -> String {
        var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasSuffix("/") {
            sanitized.removeLast()
        }

        // Users may paste either host, /v1, /jobs, or /v1/jobs.
        if sanitized.hasSuffix("/v1/jobs") {
            sanitized.removeLast("/jobs".count)
        } else if sanitized.hasSuffix("/jobs") {
            sanitized.removeLast("/jobs".count)
        }

        return sanitized
    }
}
