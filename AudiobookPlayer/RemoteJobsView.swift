import SwiftUI
import UIKit

private enum RemoteJobsScope: String, CaseIterable {
    case local
    case remote

    var title: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        }
    }
}

private enum RemoteJobsFilter: String, CaseIterable {
    case running
    case completed
    case failed

    var title: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

struct RemoteJobsView: View {
    @EnvironmentObject private var remoteJobsStore: RemoteJobsStore
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("remoteJobsEnabled") private var remoteJobsEnabled = false
    @AppStorage("remoteJobsBaseURL") private var remoteJobsBaseURL = ""
    @AppStorage("remoteJobsAuthToken") private var remoteJobsAuthToken = ""
    @Environment(\.openURL) private var openURL
    @State private var scope: RemoteJobsScope = .remote
    @State private var filter: RemoteJobsFilter = .running
    @State private var actionError: String?
    private let localRemotePrefix = "remote:"
    private let remoteAIJobMetadataKey = "remote_job_id"

    var body: some View {
        List {
            if remoteJobsEnabled {
                if remoteJobsStore.connectionState.status == .unreachable {
                    RemoteJobsBannerView(
                        message: "Server unreachable. Check your base URL or network.",
                        actionTitle: "Test Connection"
                    ) {
                        Task {
                            await remoteJobsStore.testConnection(
                                baseURL: remoteJobsBaseURL,
                                token: remoteJobsAuthToken
                            )
                        }
                    }
                    .listRowInsets(EdgeInsets())
                } else if remoteJobsStore.connectionState.status == .authFailed {
                    RemoteJobsBannerView(
                        message: "Auth failed. Update your token in Settings.",
                        actionTitle: "Open Settings"
                    ) {
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settingsURL)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                Picker("Scope", selection: $scope) {
                    ForEach(RemoteJobsScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(RemoteJobsFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if scope == .local {
                    let filteredJobs = filteredLocalJobs()
                    if filteredJobs.isEmpty {
                        ContentUnavailableView("No local jobs yet", systemImage: "tray")
                    } else {
                        ForEach(filteredJobs) { job in
                            RemoteJobRow(job: job)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteLocal(job: job) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } else if !remoteJobsEnabled {
                    ContentUnavailableView(
                        "Enable Remote Jobs in Settings to see remote jobs.",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                } else {
                    let filteredJobs = filteredRemoteJobs()
                    if filteredJobs.isEmpty {
                        ContentUnavailableView("No remote jobs yet", systemImage: "tray")
                    } else {
                        ForEach(filteredJobs) { job in
                            RemoteJobRow(
                                job: job,
                                onRetry: (job.status == .failed || job.status == .canceled)
                                    ? { Task { await retryJob(job: job) } }
                                    : nil
                            )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await forceDelete(job: job) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .labelStyle(.iconOnly)

                                    if job.status == .failed || job.status == .canceled {
                                        Button {
                                            Task { await retryJob(job: job) }
                                        } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                        }
                                        .labelStyle(.iconOnly)
                                        .tint(.blue)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Jobs")
        .alert("Error", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func filteredRemoteJobs() -> [RemoteJob] {
        applyFilter(to: remoteTranscriptionJobs() + remoteAIJobs())
    }

    private func filteredLocalJobs() -> [RemoteJob] {
        applyFilter(to: localTranscriptionJobs() + localAIJobs())
    }

    private func applyFilter(to jobs: [RemoteJob]) -> [RemoteJob] {
        switch filter {
        case .running:
            return jobs.filter { $0.status == .queued || $0.status == .running }
        case .completed:
            return jobs.filter { $0.status == .succeeded }
        case .failed:
            return jobs.filter { $0.status == .failed || $0.status == .canceled }
        }
    }

    private func localTranscriptionJobs() -> [RemoteJob] {
        let activeLocal = transcriptionManager.activeJobs.filter {
            !$0.sonioxJobId.hasPrefix(localRemotePrefix)
        }
        let activeIds = Set(activeLocal.map(\.id))
        let historyLocal = transcriptionManager.allRecentJobs.filter {
            !$0.sonioxJobId.hasPrefix(localRemotePrefix) && !activeIds.contains($0.id)
        }

        let combined = (activeLocal + historyLocal).sorted { $0.createdAt > $1.createdAt }
        return combined.map { job in
            let type: RemoteJobType = job.sonioxJobId.hasPrefix("tts-") ? .tts : .stt
            return RemoteJob(
                id: job.id,
                type: type,
                status: mapTranscriptionStatus(job.status),
                title: trackTitle(for: job, isRemote: false),
                progress: job.progress ?? 0.0,
                createdAt: job.createdAt
            )
        }
    }

    private func localAIJobs() -> [RemoteJob] {
        let activeLocal = aiGenerationManager.activeJobs.filter { !isRemoteAIJob($0) }
        let activeIds = Set(activeLocal.map(\.id))
        let historyLocal = aiGenerationManager.recentJobs.filter { $0.isTerminal && !isRemoteAIJob($0) && !activeIds.contains($0.id) }

        let combined = (activeLocal + historyLocal).sorted { $0.createdAt > $1.createdAt }
        return combined.map { job in
            RemoteJob(
                id: job.id,
                type: .ai,
                status: mapAIStatus(job.status),
                title: aiJobTitle(for: job),
                progress: job.progress ?? 0.0,
                createdAt: job.createdAt
            )
        }
    }

    private func remoteTranscriptionJobs() -> [RemoteJob] {
        let activeRemote = transcriptionManager.activeJobs.filter { $0.sonioxJobId.hasPrefix(localRemotePrefix) }
        let activeIds = Set(activeRemote.map(\.id))
        let historyRemote = transcriptionManager.allRecentJobs.filter {
            $0.sonioxJobId.hasPrefix(localRemotePrefix) && !activeIds.contains($0.id)
        }
        let combined = (activeRemote + historyRemote).sorted { $0.createdAt > $1.createdAt }
        return combined.map { job in
            RemoteJob(
                id: job.id,
                type: .stt,
                status: mapTranscriptionStatus(job.status),
                title: trackTitle(for: job, isRemote: true),
                progress: job.progress ?? 0.0,
                createdAt: job.createdAt
            )
        }
    }

    private func remoteAIJobs() -> [RemoteJob] {
        let activeRemote = aiRemoteActiveJobs()
        let activeIds = Set(activeRemote.map(\.id))
        let historyRemote = aiRemoteHistoryJobs(excluding: activeIds)
        let combined = (activeRemote + historyRemote).sorted { $0.createdAt > $1.createdAt }
        return combined.map { job in
            RemoteJob(
                id: job.id,
                type: .ai,
                status: mapAIStatus(job.status),
                title: aiJobTitle(for: job),
                progress: job.progress ?? 0.0,
                createdAt: job.createdAt
            )
        }
    }

    private func aiRemoteActiveJobs() -> [AIGenerationJob] {
        aiGenerationManager.activeJobs.filter { isRemoteAIJob($0) }
    }

    private func aiRemoteHistoryJobs(excluding activeIds: Set<String>) -> [AIGenerationJob] {
        aiGenerationManager.recentJobs.filter { $0.isTerminal && isRemoteAIJob($0) && !activeIds.contains($0.id) }
    }

    private func isRemoteAIJob(_ job: AIGenerationJob) -> Bool {
        job.decodedMetadata()?.extras?[remoteAIJobMetadataKey] != nil
    }

    private func aiJobTitle(for job: AIGenerationJob) -> String {
        if let name = job.displayName, !name.isEmpty {
            return name
        }
        switch job.type {
        case .chatTester:
            return NSLocalizedString("ai_job_type_chat_tester", comment: "")
        case .transcriptRepair:
            return NSLocalizedString("ai_job_type_transcript_repair", comment: "")
        case .trackSummary:
            return NSLocalizedString("ai_job_type_track_summary", comment: "")
        }
    }

    private func mapTranscriptionStatus(_ status: String) -> RemoteJobStatus {
        switch status {
        case "queued":
            return .queued
        case "failed":
            return .failed
        case "completed":
            return .succeeded
        case "canceled":
            return .canceled
        default:
            return .running
        }
    }

    private func mapAIStatus(_ status: AIGenerationJob.Status) -> RemoteJobStatus {
        switch status {
        case .queued:
            return .queued
        case .failed:
            return .failed
        case .completed:
            return .succeeded
        case .canceled:
            return .canceled
        case .running, .streaming:
            return .running
        }
    }

    private func deleteLocal(job: RemoteJob) async {
        switch job.type {
        case .stt, .tts:
            try? await transcriptionManager.deleteJob(jobId: job.id)
        case .ai:
            if let aiJob = aiGenerationManager.activeJobs.first(where: { $0.id == job.id })
                ?? aiGenerationManager.recentJobs.first(where: { $0.id == job.id }) {
                await aiGenerationManager.deleteJob(aiJob)
            }
        }
    }

    private func forceDelete(job: RemoteJob) async {
        let token = remoteJobsAuthToken.isEmpty ? nil : remoteJobsAuthToken

        // Get the remote server job ID before deleting locally
        let remoteId: String? = switch job.type {
        case .stt:
            transcriptionManager.activeJobs.first(where: { $0.id == job.id })?.sonioxJobId.replacingOccurrences(of: localRemotePrefix, with: "")
            ?? transcriptionManager.allRecentJobs.first(where: { $0.id == job.id })?.sonioxJobId.replacingOccurrences(of: localRemotePrefix, with: "")
        case .ai:
            aiGenerationManager.activeJobs.first(where: { $0.id == job.id }).flatMap { isRemoteAIJob($0) ? $0.decodedMetadata()?.extras?[remoteAIJobMetadataKey] : nil }
            ?? aiGenerationManager.recentJobs.first(where: { $0.id == job.id }).flatMap { isRemoteAIJob($0) ? $0.decodedMetadata()?.extras?[remoteAIJobMetadataKey] : nil }
        case .tts:
            nil
        }

        // Delete locally first (always succeeds)
        switch job.type {
        case .stt:
            try? await transcriptionManager.deleteJob(jobId: job.id)
        case .ai:
            if let aiJob = aiGenerationManager.activeJobs.first(where: { $0.id == job.id })
                ?? aiGenerationManager.recentJobs.first(where: { $0.id == job.id }) {
                await aiGenerationManager.deleteJob(aiJob)
            }
        case .tts:
            break
        }

        // Best-effort remote cancel + delete (ignore 404 and network errors)
        guard let remoteId else { return }
        if job.status == .queued || job.status == .running {
            try? await remoteJobsStore.cancelJob(jobId: remoteId, baseURL: remoteJobsBaseURL, token: token)
        }
        try? await remoteJobsStore.deleteJob(jobId: remoteId, baseURL: remoteJobsBaseURL, token: token)
    }

    private func retryJob(job: RemoteJob) async {
        guard remoteJobsEnabled,
              let baseURL = URL(string: remoteJobsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            actionError = "Remote jobs not configured."
            return
        }

        let token = remoteJobsAuthToken.isEmpty ? nil : remoteJobsAuthToken
        let client = RemoteJobsClient(config: RemoteJobsConfig(baseURL: baseURL, token: token))

        do {
            // Look up the actual remote server job ID (not the local DB UUID)
            let remoteJobId: String? = switch job.type {
            case .stt:
                transcriptionManager.activeJobs.first(where: { $0.id == job.id })?.sonioxJobId.replacingOccurrences(of: localRemotePrefix, with: "")
                ?? transcriptionManager.allRecentJobs.first(where: { $0.id == job.id })?.sonioxJobId.replacingOccurrences(of: localRemotePrefix, with: "")
            case .ai:
                aiGenerationManager.activeJobs.first(where: { $0.id == job.id }).flatMap { isRemoteAIJob($0) ? $0.decodedMetadata()?.extras?[remoteAIJobMetadataKey] : nil }
                ?? aiGenerationManager.recentJobs.first(where: { $0.id == job.id }).flatMap { isRemoteAIJob($0) ? $0.decodedMetadata()?.extras?[remoteAIJobMetadataKey] : nil }
            case .tts:
                nil
            }
            guard let remoteJobId else {
                actionError = "Could not find remote job ID."
                return
            }
            let retriedJob = try await client.retryJob(jobId: remoteJobId)
            let newRemoteId = "\(localRemotePrefix)\(retriedJob.id)"

            switch job.type {
            case .stt:
                let originalJob = transcriptionManager.activeJobs.first(where: { $0.id == job.id })
                    ?? transcriptionManager.allRecentJobs.first(where: { $0.id == job.id })
                guard let trackId = originalJob?.trackId else {
                    actionError = "Could not find original track for retry."
                    return
                }
                let localJob = try await transcriptionManager.dbManager.createTranscriptionJob(
                    trackId: trackId,
                    sonioxJobId: newRemoteId,
                    status: "transcribing",
                    progress: retriedJob.progress ?? 0.0
                )
                transcriptionManager.upsertActiveJob(localJob)
                await transcriptionManager.refreshAllRecentJobs()
                Task.detached { [newRemoteId, localJob, trackId] in
                    await self.pollRetriedSTT(client: client, remoteJobId: newRemoteId, localJobId: localJob.id, trackId: trackId)
                }

            case .ai:
                let originalJob = aiGenerationManager.activeJobs.first(where: { $0.id == job.id })
                    ?? aiGenerationManager.recentJobs.first(where: { $0.id == job.id })
                guard let originalJob else {
                    actionError = "Could not find original AI job for retry."
                    return
                }
                // Create a new local AI job tracking the retried remote job
                var metadata = originalJob.decodedMetadata() ?? AIGenerationJobMetadata(
                    flags: nil,
                    extras: nil,
                    repairResults: nil,
                    reasoning: nil
                )
                metadata = metadata.updatingExtra("remote_job_id", value: retriedJob.id)
                let encoder = JSONEncoder()
                let metadataData = try encoder.encode(metadata)
                let encodedMetadata = String(data: metadataData, encoding: .utf8)

                let newLocalJob = try await aiGenerationManager.dbManager.createAIGenerationJob(
                    type: originalJob.type,
                    modelId: originalJob.modelId,
                    trackId: originalJob.trackId,
                    transcriptId: originalJob.transcriptId,
                    sourceContext: originalJob.sourceContext,
                    displayName: originalJob.displayName,
                    systemPrompt: originalJob.systemPrompt,
                    userPrompt: originalJob.userPrompt,
                    payloadJSON: originalJob.payloadJSON,
                    metadataJSON: encodedMetadata,
                    initialStatus: .running
                )
                await aiGenerationManager.refreshJobs()
                Task.detached { [newRemoteId, newLocalJob] in
                    await self.pollRetriedAI(client: client, remoteJobId: newRemoteId, localJobId: newLocalJob.id)
                }

            case .tts:
                actionError = "TTS retry not yet supported."
                return
            }

        } catch {
            actionError = "Retry failed: \(error.localizedDescription)"
        }
    }

    private func pollRetriedSTT(client: RemoteJobsClient, remoteJobId: String, localJobId: String, trackId: String) async {
        let maxPolling: TimeInterval = 3600
        let interval: TimeInterval = 2
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxPolling {
            do {
                let status = try await client.fetchJob(jobId: remoteJobId)
                let localStatus: String
                if status.status == "running" || status.status == "queued" {
                    localStatus = "transcribing"
                } else if status.status == "succeeded" {
                    localStatus = "completed"
                } else {
                    localStatus = status.status
                }
                try await transcriptionManager.dbManager.updateJobStatus(
                    jobId: localJobId,
                    status: localStatus,
                    progress: status.progress ?? 0.0
                )

                if status.status == "succeeded" {
                    let result = try await client.fetchSTTResult(jobId: remoteJobId)
                    let srtText = result.srt ?? ""
                    let transcriptText = result.transcript ?? ""
                    let transcriptId = UUID().uuidString
                    let segments = transcriptionManager.parseSRTSegments(srtText, transcriptId: transcriptId)
                    let fullText = transcriptText.isEmpty ? segments.map { $0.text }.joined(separator: "\n") : transcriptText
                    let transcript = Transcript(
                        id: transcriptId,
                        trackId: trackId,
                        collectionId: "",
                        language: "en",
                        fullText: fullText,
                        createdAt: Date(),
                        updatedAt: Date(),
                        jobStatus: "complete",
                        jobId: "\(localRemotePrefix)\(remoteJobId)",
                        errorMessage: nil
                    )
                    try transcriptionManager.dbManager.saveTranscript(transcript, segments: segments)
                    try transcriptionManager.dbManager.markJobCompleted(jobId: localJobId)
                    transcriptionManager.removeActiveJob(jobId: localJobId)
                    await transcriptionManager.refreshAllRecentJobs()
                    return
                } else if status.status == "failed" {
                    try transcriptionManager.dbManager.markJobFailed(
                        jobId: localJobId,
                        errorMessage: "Remote job failed"
                    )
                    transcriptionManager.removeActiveJob(jobId: localJobId)
                    return
                }

                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                try? transcriptionManager.dbManager.markJobFailed(
                    jobId: localJobId,
                    errorMessage: error.localizedDescription
                )
                transcriptionManager.removeActiveJob(jobId: localJobId)
                return
            }
        }
    }

    private func pollRetriedAI(client: RemoteJobsClient, remoteJobId: String, localJobId: String) async {
        let maxPolling: TimeInterval = 3600
        let interval: TimeInterval = 2
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxPolling {
            do {
                let status = try await client.fetchJob(jobId: remoteJobId)
                try? aiGenerationManager.dbManager.updateAIGenerationJobStatus(
                    jobId: localJobId,
                    status: status.status == "succeeded" ? .completed : .running,
                    progress: status.progress
                )

                if status.status == "succeeded" {
                    let result = try await client.fetchAIResult(jobId: remoteJobId)
                    try? aiGenerationManager.dbManager.markAIGenerationJobCompleted(
                        jobId: localJobId,
                        finalOutput: result.text,
                        usageJSON: nil
                    )
                    await aiGenerationManager.refreshJobs()
                    return
                } else if status.status == "failed" {
                    try? aiGenerationManager.dbManager.markAIGenerationJobFailed(
                        jobId: localJobId,
                        errorMessage: "Remote job failed"
                    )
                    await aiGenerationManager.refreshJobs()
                    return
                }

                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                try? aiGenerationManager.dbManager.markAIGenerationJobFailed(
                    jobId: localJobId,
                    errorMessage: error.localizedDescription
                )
                await aiGenerationManager.refreshJobs()
                return
            }
        }
    }

    private func trackTitle(for job: TranscriptionJob, isRemote: Bool) -> String {
        if let track = library.collections.flatMap(\.tracks).first(where: { $0.id.uuidString == job.trackId }) {
            return track.displayName
        }

        if job.sonioxJobId.hasPrefix("tts-") {
            return isRemote ? "Remote TTS" : "Local TTS"
        }

        return isRemote ? "Remote STT" : "Local STT"
    }
}

private struct RemoteJobRow: View {
    let job: RemoteJob
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(job.title, systemImage: iconName)
                Spacer()
                Text(job.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            HStack(spacing: 8) {
                Text(job.type.badgeLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color(.secondarySystemFill))
                    )
                Text(job.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
            HStack {
                Text(job.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch job.status {
        case .failed, .canceled: return .red
        case .succeeded: return .green
        case .running, .queued: return .blue
        }
    }

    private var iconName: String {
        switch job.type {
        case .stt: return "waveform"
        case .tts: return "speaker.wave.2"
        case .ai: return "sparkles"
        }
    }
}

private struct RemoteJobsBannerView: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                Button(actionTitle, action: action)
                    .font(.subheadline)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }
}
