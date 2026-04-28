import SwiftUI
import UIKit

private enum RemoteJobsStatusFilter: String, CaseIterable {
    case all
    case running
    case completed
    case failed

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

private enum RemoteJobsTypeFilter: String, CaseIterable {
    case all
    case stt
    case ai
    case tts

    var title: String {
        switch self {
        case .all: return "All"
        case .stt: return "STT"
        case .ai: return "AI"
        case .tts: return "TTS"
        }
    }
}

/// Pre-built lookup tables used to avoid O(N*M) enrichment on every body eval.
private struct EnrichmentIndex {
    /// Remote job id -> track display name / type override for STT/TTS jobs.
    var sttTitleByJobId: [String: String] = [:]
    var ttsJobIds: Set<String> = []
    /// Remote job id -> AI job display title.
    var aiTitleByJobId: [String: String] = [:]
}

struct RemoteJobsView: View {
    @EnvironmentObject private var remoteJobsStore: RemoteJobsStore
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("remoteJobsEnabled") private var remoteJobsEnabled = false
    @AppStorage("remoteJobsBaseURL") private var remoteJobsBaseURL = ""
    @AppStorage("remoteJobsAuthToken") private var remoteJobsAuthToken = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var statusFilter: RemoteJobsStatusFilter = .all
    @State private var typeFilter: RemoteJobsTypeFilter = .all
    @State private var actionError: String?
    @State private var isViewVisible = false
    @State private var nowTick: Date = Date()
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
                Picker("Status", selection: $statusFilter) {
                    ForEach(RemoteJobsStatusFilter.allCases, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                // Type filter — compact chip row
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(RemoteJobsTypeFilter.allCases, id: \.self) { f in
                            let selected = typeFilter == f
                            Button { typeFilter = f } label: {
                                Text(f.title)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selected ? Color.accentColor : Color(.tertiarySystemFill))
                                    )
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .animation(.easeInOut(duration: 0.15), value: selected)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if !remoteJobsEnabled {
                    ContentUnavailableView(
                        "Enable Remote Jobs in Settings to see remote jobs.",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                } else if remoteJobsStore.isFetchingJobs && remoteJobsStore.jobs.isEmpty && remoteJobsStore.lastFetchedAt == nil {
                    HStack {
                        Spacer()
                        ProgressView("Loading jobs…")
                        Spacer()
                    }
                } else {
                    let jobs = displayedRemoteJobs()
                    if jobs.isEmpty {
                        ContentUnavailableView("No remote jobs yet", systemImage: "tray")
                    } else {
                        ForEach(jobs) { job in
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
            } footer: {
                if remoteJobsEnabled, let subtitle = lastUpdatedSubtitle() {
                    HStack(spacing: 4) {
                        if remoteJobsStore.isFetchingJobs {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(subtitle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshRemoteJobs(reportErrors: true, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!remoteJobsEnabled || remoteJobsStore.isFetchingJobs)
            }
        }
        .refreshable {
            await refreshRemoteJobs(reportErrors: false, force: true)
        }
        .onAppear {
            isViewVisible = true
        }
        .onDisappear {
            isViewVisible = false
        }
        .task(id: pollingTaskID) {
            await pollRemoteJobs()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && isViewVisible {
                Task { await refreshRemoteJobs(reportErrors: false) }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { date in
            nowTick = date
        }
    }

    /// Polling task ID — restarts polling only when these change.
    /// Filter changes do NOT affect polling anymore (fetch is status-agnostic).
    /// scenePhase is intentionally NOT included — we handle foreground refreshes
    /// via a dedicated onChange handler with throttling in the store.
    private var pollingTaskID: String {
        "\(remoteJobsEnabled)|\(remoteJobsBaseURL)|\(isViewVisible)"
    }

    private func lastUpdatedSubtitle() -> String? {
        guard let last = remoteJobsStore.lastFetchedAt else {
            return remoteJobsStore.isFetchingJobs ? "Loading…" : nil
        }
        _ = nowTick // force re-evaluate when ticker fires
        let elapsed = Int(Date().timeIntervalSince(last))
        let timeText: String
        if elapsed < 5 {
            timeText = "just now"
        } else if elapsed < 60 {
            timeText = "\(elapsed)s ago"
        } else if elapsed < 3600 {
            timeText = "\(elapsed / 60)m ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            timeText = formatter.string(from: last)
        }
        return "Updated \(timeText)"
    }

    /// Build enrichment lookup once per displayed jobs call instead of scanning
    /// library/transcription/AI managers per row.
    private func buildEnrichmentIndex() -> EnrichmentIndex {
        var index = EnrichmentIndex()

        // Transcription jobs (STT/TTS) — map remote job id -> track title.
        let transcriptionJobs = transcriptionManager.activeJobs + transcriptionManager.allRecentJobs
        if !transcriptionJobs.isEmpty {
            // Pre-index tracks by id string.
            var trackNames: [String: String] = [:]
            for collection in library.collections {
                for track in collection.tracks {
                    trackNames[track.id.uuidString] = track.displayName
                }
            }
            for job in transcriptionJobs {
                let sid = job.sonioxJobId
                guard sid.hasPrefix(localRemotePrefix) else { continue }
                let remoteId = String(sid.dropFirst(localRemotePrefix.count))
                let isTTS = sid.hasPrefix("tts-") // preserved from legacy logic
                if isTTS {
                    index.ttsJobIds.insert(remoteId)
                }
                let title = trackNames[job.trackId] ?? (sid.hasPrefix("tts-") ? "Remote TTS" : "Remote STT")
                index.sttTitleByJobId[remoteId] = title
            }
        }

        // AI jobs — map remote job id -> display title.
        let aiJobs = aiGenerationManager.activeJobs + aiGenerationManager.recentJobs
        for job in aiJobs {
            guard let remoteId = job.decodedMetadata()?.extras?[remoteAIJobMetadataKey] else { continue }
            index.aiTitleByJobId[remoteId] = aiJobTitle(for: job)
        }

        return index
    }

    private func displayedRemoteJobs() -> [RemoteJob] {
        let index = buildEnrichmentIndex()
        let enriched = remoteJobsStore.jobs.map { job -> RemoteJob in
            var e = job
            switch job.type {
            case .ai:
                if let t = index.aiTitleByJobId[job.id] {
                    e.title = t
                }
            case .stt, .tts:
                if let t = index.sttTitleByJobId[job.id] {
                    e.title = t
                }
                if index.ttsJobIds.contains(job.id) {
                    e.type = .tts
                }
            }
            return e
        }

        let filteredByStatus: [RemoteJob]
        if statusFilter == .all {
            filteredByStatus = enriched
        } else {
            let allowedStatuses: Set<String> = {
                switch statusFilter {
                case .running: return ["queued", "running"]
                case .completed: return ["succeeded"]
                case .failed: return ["failed", "canceled"]
                case .all: return []
                }
            }()
            filteredByStatus = enriched.filter { allowedStatuses.contains($0.status.rawValue) }
        }
        switch typeFilter {
        case .all:
            return filteredByStatus
        case .stt:
            return filteredByStatus.filter { $0.type == .stt }
        case .ai:
            return filteredByStatus.filter { $0.type == .ai }
        case .tts:
            return filteredByStatus.filter { $0.type == .tts }
        }
    }

    private func refreshRemoteJobs(reportErrors: Bool = true, force: Bool = false) async {
        guard remoteJobsEnabled else { return }
        let token = remoteJobsAuthToken.isEmpty ? nil : remoteJobsAuthToken
        do {
            try await remoteJobsStore.fetchJobs(
                baseURL: remoteJobsBaseURL,
                token: token,
                statuses: [], // Always fetch all; filter client-side.
                force: force
            )
        } catch {
            if reportErrors {
                actionError = "Refresh failed: \(error.localizedDescription)"
            }
        }
    }

    /// Smart polling loop.
    /// - Only runs when: remote jobs enabled, view visible, scene active.
    /// - Only polls while there are active (queued/running) jobs.
    /// - Idle state relies on manual pull-to-refresh or foreground activation.
    private func pollRemoteJobs() async {
        guard remoteJobsEnabled, isViewVisible, scenePhase == .active else { return }

        // Initial refresh when polling task starts.
        await refreshRemoteJobs(reportErrors: false)

        while !Task.isCancelled {
            let hasActiveJobs = remoteJobsStore.jobs.contains { $0.status == .queued || $0.status == .running }
            if !hasActiveJobs {
                // No active jobs — stop the polling loop. Refreshes come from
                // pull-to-refresh, toolbar button, or scenePhase .active.
                break
            }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard !Task.isCancelled else { break }
            await refreshRemoteJobs(reportErrors: false)
        }
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

    private func forceDelete(job: RemoteJob) async {
        let token = remoteJobsAuthToken.isEmpty ? nil : remoteJobsAuthToken
        do {
            // Server auto-cancels running/queued jobs before delete.
            try await remoteJobsStore.deleteJob(jobId: job.id, baseURL: remoteJobsBaseURL, token: token)
            await refreshRemoteJobs(reportErrors: false, force: true)
        } catch {
            actionError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func retryJob(job: RemoteJob) async {
        guard remoteJobsEnabled else { return }
        let token = remoteJobsAuthToken.isEmpty ? nil : remoteJobsAuthToken
        do {
            try await remoteJobsStore.retryJob(jobId: job.id, baseURL: remoteJobsBaseURL, token: token)
            await refreshRemoteJobs(reportErrors: false, force: true)
        } catch {
            actionError = "Retry failed: \(error.localizedDescription)"
        }
    }
}

private struct RemoteJobRow: View {
    let job: RemoteJob
    var onRetry: (() -> Void)? = nil
    @State private var showCopied = false

    private var isActive: Bool {
        job.status == .running || job.status == .queued
    }

    private var isOlderThanToday: Bool {
        !Calendar.current.isDateInToday(job.createdAt)
    }

    /// Shorten e.g. "job_17f3f81376c342d18b6299ee1b444e54" → "17f3f813…444e54"
    private var shortID: String {
        var id = job.id
        if id.hasPrefix("job_") { id = String(id.dropFirst(4)) }
        guard id.count > 16 else { return id }
        return "\(id.prefix(8))…\(id.suffix(6))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: icon + title + status pill
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.body)
                    .foregroundStyle(typeColor)
                    .frame(width: 22)
                Text(job.title)
                    .font(.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                StatusPillView(status: job.status)
            }

            // Row 2: type badge + short ID (copyable) + date
            HStack(spacing: 6) {
                Text(job.type.badgeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))

                Button {
                    UIPasteboard.general.string = job.id
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(showCopied ? "Copied!" : shortID)
                            .font(.caption2)
                            .foregroundStyle(showCopied ? .green : .secondary)
                            .monospacedDigit()
                        if !showCopied {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Group {
                    if isOlderThanToday {
                        Text(job.createdAt, style: .date)
                    } else {
                        Text(job.createdAt, style: .time)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // Row 3: progress (active only)
            if isActive {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            // Row 4: error message
            if let msg = job.errorMessage, !msg.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                    Text(msg)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(.red)
            }

            // Row 5: retry button (failed/canceled)
            if let onRetry {
                HStack {
                    Spacer()
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var typeColor: Color {
        switch job.type {
        case .stt: return .indigo
        case .tts: return .teal
        case .ai: return .purple
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

/// Colored pill showing job status.
private struct StatusPillView: View {
    let status: RemoteJobStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .queued:    return "Queued"
        case .running:   return "Running"
        case .succeeded: return "Done"
        case .failed:    return "Failed"
        case .canceled:  return "Canceled"
        }
    }

    private var foreground: Color {
        switch status {
        case .queued:    return .orange
        case .running:   return .blue
        case .succeeded: return .green
        case .failed, .canceled: return .red
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
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
