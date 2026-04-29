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

enum RemoteJobType: String, CaseIterable, Codable {
    case stt
    case tts
    case ai
}

enum RemoteJobStatus: String, CaseIterable, Codable {
    case queued
    case running
    case succeeded
    case failed
    case canceled
}

struct RemoteJob: Identifiable, Hashable, Codable {
    let id: String
    var type: RemoteJobType
    var subtype: String?
    var status: RemoteJobStatus
    var title: String
    var progress: Double
    var createdAt: Date
    var errorMessage: String?
    var taskId: String?
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
    @Published var isFetchingJobs = false
    @Published var lastFetchedAt: Date?

    /// Minimum interval between successful fetch triggers. Rapid duplicate calls
    /// within this window are coalesced (except forced refreshes).
    private let minFetchInterval: TimeInterval = 3.0

    /// Tracks in-flight fetch task for deduplication.
    private var inFlightFetch: Task<Void, Error>?
    private var lastFetchStartedAt: Date?

    // MARK: - Disk persistence

    private static let cacheFilename = "remote_jobs_cache.json"
    private static let cacheURL: URL = {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent(cacheFilename)
    }()

    private struct CachedPayload: Codable {
        let jobs: [RemoteJob]
        let fetchedAt: Date
    }

    init() {
        loadCachedJobs()
    }

    private func loadCachedJobs() {
        let url = Self.cacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(CachedPayload.self, from: data)
            self.jobs = payload.jobs
            self.lastFetchedAt = payload.fetchedAt
        } catch {
            // Ignore cache load errors — start fresh.
        }
    }

    private func persistJobs() {
        let payload = CachedPayload(jobs: self.jobs, fetchedAt: self.lastFetchedAt ?? Date())
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                // Ignore persistence errors.
            }
        }
    }

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

    /// Max pages to fetch per status filter. Prevents runaway requests when
    /// user has thousands of historical jobs.
    private let maxPagesPerStatus = 3
    private let pageSize = 100

    /// Fetch jobs with request deduplication + throttling.
    /// - Parameters:
    ///   - force: If true, bypasses the min-interval throttle (e.g. pull-to-refresh).
    func fetchJobs(baseURL: String, token: String?, statuses: [RemoteJobStatus], force: Bool = false) async throws {
        // Deduplicate concurrent calls — await the existing task instead of starting a new one.
        if let existing = inFlightFetch {
            try await existing.value
            return
        }

        // Throttle: unless forced, skip if last fetch started too recently.
        if !force, let last = lastFetchStartedAt, Date().timeIntervalSince(last) < minFetchInterval {
            return
        }

        // Mark start time BEFORE kicking off the task so subsequent callers
        // hitting the throttle see the correct window.
        lastFetchStartedAt = Date()

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performFetch(baseURL: baseURL, token: token, statuses: statuses)
        }
        inFlightFetch = task
        // IMPORTANT: defer runs on this function's return, but task continues.
        // Clear in-flight pointer only AFTER the task actually finishes, so
        // concurrent callers correctly see the in-flight state.
        do {
            try await task.value
            inFlightFetch = nil
        } catch {
            inFlightFetch = nil
            throw error
        }
    }

    private func performFetch(baseURL: String, token: String?, statuses: [RemoteJobStatus]) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        isFetchingJobs = true
        defer { isFetchingJobs = false }

        let client = RemoteJobsClient(config: config)
        var fetchedJobs: [RemoteJobDTO] = []

        if statuses.isEmpty {
            // No status filter — fetch all jobs
            var cursor: String?
            var pagesFetched = 0
            repeat {
                let page = try await client.fetchJobs(limit: pageSize, status: nil, cursor: cursor)
                fetchedJobs.append(contentsOf: page.jobs)
                cursor = page.nextCursor
                pagesFetched += 1
            } while cursor != nil && pagesFetched < maxPagesPerStatus
        } else {
            var seenStatuses = Set<String>()
            let requestedStatuses = statuses.map(\.rawValue).filter { seenStatuses.insert($0).inserted }
            for status in requestedStatuses {
                var cursor: String?
                var pagesFetched = 0
                repeat {
                    let page = try await client.fetchJobs(limit: pageSize, status: status, cursor: cursor)
                    fetchedJobs.append(contentsOf: page.jobs)
                    cursor = page.nextCursor
                    pagesFetched += 1
                } while cursor != nil && pagesFetched < maxPagesPerStatus
            }
        }

        jobs = deduplicatedJobs(from: fetchedJobs.map(Self.mapRemoteJob))
        lastFetchedAt = Date()
        persistJobs()
    }

    func cancelJob(jobId: String, baseURL: String, token: String?) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        let client = RemoteJobsClient(config: config)
        _ = try await client.cancelJob(jobId: jobId)
    }

    func retryJob(jobId: String, baseURL: String, token: String?) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        let client = RemoteJobsClient(config: config)
        _ = try await client.retryJob(jobId: jobId)
    }

    func deleteJob(jobId: String, baseURL: String, token: String?) async throws {
        guard let config = makeConfig(baseURL: baseURL, token: token) else {
            throw RemoteJobsClientError.invalidBaseURL
        }
        let client = RemoteJobsClient(config: config)
        try await client.deleteJob(jobId: jobId)
        // Optimistically remove from local cache.
        jobs.removeAll { $0.id == jobId }
        persistJobs()
    }

    private func makeConfig(baseURL: String, token: String?) -> RemoteJobsConfig? {
        let normalized = normalizeBaseURLString(baseURL)
        guard let url = URL(string: normalized), url.scheme != nil else { return nil }
        return RemoteJobsConfig(baseURL: url, token: token)
    }

    private static func mapRemoteJob(_ dto: RemoteJobDTO) -> RemoteJob {
        RemoteJob(
            id: dto.id,
            type: RemoteJobType(rawValue: dto.type) ?? .stt,
            subtype: dto.subtype,
            status: RemoteJobStatus(rawValue: dto.status) ?? .running,
            title: remoteJobTitle(from: dto),
            progress: dto.progress ?? 0.0,
            createdAt: parseDate(dto.createdAt) ?? Date(),
            errorMessage: dto.error?.message,
            taskId: dto.taskId
        )
    }

    private static func remoteJobTitle(from dto: RemoteJobDTO) -> String {
        if let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        if let subtypeTitle = aiSubtypeTitle(from: dto), !subtypeTitle.isEmpty {
            return subtypeTitle
        }

        if let urlString = dto.input?.url, let title = titleFromRemoteURL(urlString), !title.isEmpty {
            return title
        }

        let type = RemoteJobType(rawValue: dto.type) ?? .stt
        return "Remote \(type.badgeLabel)"
    }

    private static func titleFromRemoteURL(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }

        if let baiduPath = components.queryItems?.first(where: { $0.name == "path" })?.value {
            let fileName = URL(fileURLWithPath: baiduPath).lastPathComponent
            return fileName.removingPercentEncoding ?? fileName
        }

        guard let url = components.url else { return nil }
        let fileName = url.lastPathComponent
        return fileName.removingPercentEncoding ?? fileName
    }

    private static func aiSubtypeTitle(from dto: RemoteJobDTO) -> String? {
        guard dto.type == RemoteJobType.ai.rawValue else { return nil }

        switch dto.subtype {
        case "chat_tester":
            return NSLocalizedString("ai_job_type_chat_tester", comment: "")
        case "transcript_repair":
            return NSLocalizedString("ai_job_type_transcript_repair", comment: "")
        case "track_summary":
            return NSLocalizedString("ai_job_type_track_summary", comment: "")
        default:
            return nil
        }
    }

    private func deduplicatedJobs(from jobs: [RemoteJob]) -> [RemoteJob] {
        var seen = Set<String>()
        return jobs
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
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
