import Foundation

@MainActor
final class TrackSummaryViewModel: ObservableObject {
    struct TranscriptStats {
        let segmentCount: Int
        let characterCount: Int
    }

    @Published private(set) var summary: TrackSummary?
    @Published private(set) var sections: [TrackSummarySection] = []
    @Published private(set) var status: TrackSummary.Status = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var activeJob: AIGenerationJob?
    @Published private(set) var transcriptStats: TranscriptStats?

    private let dbManager: GRDBDatabaseManager
    private var currentTrackId: String?
    private let trackSummaryGenerator = TrackSummaryGenerator()
    private var attemptedSectionRecovery: Set<String> = []

    init(dbManager: GRDBDatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    func setTrackId(_ trackId: String?) {
        guard trackId != currentTrackId else { return }
        currentTrackId = trackId
        transcriptStats = nil
        Task { await loadSummary() }
    }

    func loadSummary() async {
        guard let trackId = currentTrackId else {
            summary = nil
            sections = []
            status = .idle
            errorMessage = nil
            transcriptStats = nil
            return
        }

        isLoading = true
        errorMessage = nil
        transcriptStats = nil

        do {
            try await dbManager.initializeDatabase()

            if let transcript = try await dbManager.loadTranscript(forTrackId: trackId) {
                let segmentCount = try await dbManager.countTranscriptSegments(forTranscriptId: transcript.id)
                transcriptStats = TranscriptStats(
                    segmentCount: segmentCount,
                    characterCount: transcript.fullText.count
                )
            } else {
                transcriptStats = nil
            }

            if let bundle = try await dbManager.fetchTrackSummaryBundle(forTrackId: trackId) {
                summary = bundle.0
                sections = bundle.1
                status = bundle.0.status
                errorMessage = bundle.0.errorMessage

                if summary?.status == .complete,
                   (summary?.sectionCount ?? 0) == 0,
                   sections.isEmpty,
                   await recoverSectionsIfNeeded(for: bundle.0) {
                    if let refreshed = try await dbManager.fetchTrackSummaryBundle(forTrackId: trackId) {
                        summary = refreshed.0
                        sections = refreshed.1
                        status = refreshed.0.status
                        errorMessage = refreshed.0.errorMessage
                    }
                }
            } else {
                summary = nil
                sections = []
                status = .idle
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func handleJobUpdates(activeJobs: [AIGenerationJob], recentJobs: [AIGenerationJob]) {
        guard let trackId = currentTrackId else {
            activeJob = nil
            return
        }

        let matchingJob = (activeJobs + recentJobs).first { job in
            guard job.type == .trackSummary else { return false }
            return job.trackId == trackId
        }

        let previousJobId = activeJob?.id
        let previousStatus = activeJob?.status
        activeJob = matchingJob

        if let matchingJob {
            if matchingJob.isTerminal && (matchingJob.id != previousJobId || matchingJob.status != previousStatus) {
                Task { await loadSummary() }
            } else if matchingJob.status == .running || matchingJob.status == .streaming {
                status = .generating
            }
        } else if previousJobId != nil {
            Task { await loadSummary() }
        }
    }

    func handleTranscriptFinalized(trackId: String) {
        guard let currentTrackId, currentTrackId == trackId else { return }
        Task { await loadSummary() }
    }

    func startGeneration(
        using manager: AIGenerationManager,
        modelId: String,
        targetSections: Int? = nil,
        includeKeywords: Bool = true
    ) async throws {
        guard let trackId = currentTrackId else {
            throw AIGatewayRequestError(message: NSLocalizedString("track_summary_missing_track", comment: ""))
        }
        guard !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayRequestError(message: NSLocalizedString("ai_tab_missing_model", comment: "Model missing"))
        }

        let job = try await manager.enqueueTrackSummaryJob(
            trackId: trackId,
            targetSectionCount: targetSections,
            includeKeywords: includeKeywords,
            modelId: modelId
        )
        activeJob = job
        status = .generating
    }

    func hasSummaryContent() -> Bool {
        if let summary, summary.isReady {
            return true
        }
        return false
    }

    private func recoverSectionsIfNeeded(for summary: TrackSummary) async -> Bool {
        guard let trackId = currentTrackId else { return false }
        guard summary.status == .complete else { return false }
        guard summary.sectionCount == 0 else { return false }
        guard attemptedSectionRecovery.insert(trackId).inserted else { return false }
        guard let jobId = summary.lastJobId else { return false }

        do {
            guard let job = try await dbManager.loadAIGenerationJob(jobId: jobId),
                  let raw = job.streamedOutput else {
                return false
            }

            let parsed = try trackSummaryGenerator.parseResponse(raw)
            guard !parsed.sections.isEmpty else { return false }

            let recoveredSections = parsed.sections.enumerated().map { index, payload in
                TrackSummarySection(
                    trackSummaryId: summary.trackId,
                    orderIndex: index,
                    startTimeMs: payload.startTimeMs,
                    endTimeMs: payload.endTimeMs,
                    title: payload.title,
                    summary: payload.summary,
                    keywords: payload.keywords
                )
            }

            _ = try await dbManager.persistTrackSummaryResult(
                trackId: summary.trackId,
                transcriptId: summary.transcriptId,
                language: summary.language,
                summaryTitle: parsed.summaryTitle ?? summary.summaryTitle,
                summaryBody: parsed.summaryBody,
                keywords: parsed.keywords,
                sections: recoveredSections,
                modelIdentifier: summary.modelIdentifier,
                jobId: jobId
            )
            return true
        } catch {
            print("TrackSummaryViewModel recovery failed: \(error.localizedDescription)")
            return false
        }
    }
}
