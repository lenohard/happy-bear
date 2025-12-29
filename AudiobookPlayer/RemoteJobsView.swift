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
                    ContentUnavailableView(
                        "Local jobs are listed in STT/TTS/AI screens.",
                        systemImage: "tray"
                    )
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
                            RemoteJobRow(job: job)
                        }
                    }
                }
            }
        }
        .navigationTitle("Jobs")
    }

    private func filteredRemoteJobs() -> [RemoteJob] {
        let jobs = remoteTranscriptionJobs() + remoteAIJobs()
        switch filter {
        case .running:
            return jobs.filter { $0.status == .queued || $0.status == .running }
        case .completed:
            return jobs.filter { $0.status == .succeeded }
        case .failed:
            return jobs.filter { $0.status == .failed || $0.status == .canceled }
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
                status: mapRemoteStatus(job.status),
                title: trackTitle(for: job),
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

    private func mapRemoteStatus(_ status: String) -> RemoteJobStatus {
        switch status {
        case "queued":
            return .queued
        case "failed":
            return .failed
        case "completed":
            return .succeeded
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

    private func trackTitle(for job: TranscriptionJob) -> String {
        if let track = library.collections.flatMap(\.tracks).first(where: { $0.id.uuidString == job.trackId }) {
            return track.displayName
        }
        return "Remote STT"
    }
}

private struct RemoteJobRow: View {
    let job: RemoteJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(job.title, systemImage: iconName)
                Spacer()
                Text(job.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
            Text(job.createdAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
