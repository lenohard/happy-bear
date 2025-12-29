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
        guard let base = URL(string: baseURL), base.scheme != nil else {
            return nil
        }
        var sanitized = baseURL
        while sanitized.hasSuffix("/") {
            sanitized.removeLast()
        }
        if sanitized.hasSuffix("/v1") {
            return URL(string: "\(sanitized)/jobs?limit=1")
        }
        return URL(string: "\(sanitized)/v1/jobs?limit=1")
    }
}
