import SwiftUI
import OSLog

/// Sheet for transcribing a single track
struct TranscriptionSheet: View {
    let track: AudiobookTrack
    let collectionID: UUID
    let collectionTitle: String
    let collectionDescription: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var isTranscribing = false
    @State private var progress: Double = 0.0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var transcriptionCompleted = false
    @State private var stage: Stage = .idle
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var contextText: String = ""
    @State private var mirroredJobId: String?
    @State private var downloadJobId: String?
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "TranscriptionSheet")

    private enum Stage {
        case idle
        case downloading
        case uploading
        case transcribing
        case processing
        case finalizing
        case completed

        var messageKey: String {
            switch self {
            case .downloading:
                return "transcription_step_downloading"
            case .uploading:
                return "transcription_step_uploading"
            case .transcribing:
                return "transcription_step_transcribing"
            case .processing:
                return "transcription_step_processing"
            case .finalizing:
                return "transcription_step_finalizing"
            default:
                return ""
            }
        }

        var debugName: String {
            switch self {
            case .idle: return "idle"
            case .downloading: return "downloading"
            case .uploading: return "uploading"
            case .transcribing: return "transcribing"
            case .processing: return "processing"
            case .finalizing: return "finalizing"
            case .completed: return "completed"
            }
        }

        init(jobStatus: String) {
            switch jobStatus {
            case "downloading": self = .downloading
            case "uploading": self = .uploading
            case "transcribing", "processing": self = .transcribing
            case "completed": self = .completed
            case "failed": self = .processing
            default: self = .idle
            }
        }
    }

    @MainActor
    private func setStage(_ newStage: Stage, reason: String) {
        let previous = stage
        if previous == newStage {
            logger.debug("[TranscriptionSheet] Stage remains \(previous.debugName, privacy: .public) – \(reason, privacy: .public)")
            return
        }
        logger.info(
            "[TranscriptionSheet] Stage \(previous.debugName, privacy: .public) → \(newStage.debugName, privacy: .public) – track \(track.id.uuidString, privacy: .public); reason: \(reason, privacy: .public)"
        )
        stage = newStage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Track info
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)

                    Text(track.displayName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Text(formatBytes(track.fileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                Spacer()

                // Progress section
                if isTranscribing {
                    VStack(spacing: 16) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .scaleEffect(y: 2)

                        VStack(spacing: 4) {
                            if !stage.messageKey.isEmpty {
                                Text(NSLocalizedString(stage.messageKey, comment: ""))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if stage == .downloading, totalBytes > 0 {
                                Text(String(format: NSLocalizedString("transcription_progress_download", comment: ""), formatBytes(downloadedBytes), formatBytes(totalBytes)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if stage == .uploading, totalBytes > 0 {
                                Text(String(format: NSLocalizedString("transcription_progress_upload", comment: ""), formatBytes(downloadedBytes), formatBytes(totalBytes)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)

                        processTimeline
                    }
                    .padding(.horizontal, 32)
                } else if transcriptionCompleted {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)

                        Text("transcription_completed")
                            .font(.headline)

                        Text("transcription_completed_message")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                } else {
                    VStack(spacing: 16) {
                        Text("transcription_ready_message")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        contextEditor

                        Button {
                            startTranscription()
                        } label: {
                            Label("start_transcription", systemImage: "waveform")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTranscribing)
                        .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
            .navigationTitle("transcribe_track_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if transcriptionCompleted || !isTranscribing {
                        Button("close_button") {
                            dismiss()
                        }
                    }
                }
            }
            .alert("transcription_error_title", isPresented: $showError) {
                Button("ok_button", role: .cancel) {
                    showError = false
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
            .onAppear {
                if contextText.isEmpty {
                    contextText = buildDefaultContext()
                }
                mirrorExistingJobIfNeeded()
            }
            .onReceive(transcriptionManager.$activeJobs) { _ in
                mirrorExistingJobIfNeeded()
            }
        }
    }

    private var statusMessage: String {
        NSLocalizedString(stage.messageKey, comment: "")
    }

    @MainActor
    private func startTranscription() {
        logger.info("[TranscriptionSheet] User initiated transcription for track \(track.id.uuidString, privacy: .public) (\(track.displayName, privacy: .public)) size=\(track.fileSize) bytes")
        if transcriptionManager.activeJobs.contains(where: { $0.trackId == track.id.uuidString }) {
            logger.info("[TranscriptionSheet] Existing job already running for track \(track.id.uuidString, privacy: .public) – mirroring instead of starting a duplicate")
            mirrorExistingJobIfNeeded()
            return
        }
        isTranscribing = true
        progress = 0.0
        errorMessage = nil
        transcriptionCompleted = false
        downloadedBytes = 0
        totalBytes = max(track.fileSize, 0)
        setStage(.downloading, reason: "User tapped Start; beginning cache download")

        Task {
            do {
                let hasDownloadJob = await MainActor.run { downloadJobId != nil }
                if !hasDownloadJob {
                    if let placeholder = await transcriptionManager.beginDownloadJob(for: track.id) {
                        await MainActor.run {
                            downloadJobId = placeholder.id
                            mirroredJobId = placeholder.id
                        }
                        logger.info("[TranscriptionSheet] Created placeholder download job \(placeholder.id, privacy: .public) for track \(track.id.uuidString, privacy: .public)")
                    }
                }
                // Resolve a local URL that can be uploaded to Soniox
                let audioURL = try await getAudioFileURL(
                    track: track,
                    token: authViewModel.token,
                    progressHandler: { received, total in
                        await MainActor.run {
                            downloadedBytes = received
                            totalBytes = total
                            if total > 0, stage == .downloading {
                                let fraction = max(Double(received) / Double(total), 0.02)
                                let scaledProgress = min(0.25, fraction * 0.25)
                                progress = max(progress, scaledProgress)
                            }
                        }
                        let jobId = await MainActor.run { downloadJobId }
                        if let jobId {
                            await transcriptionManager.updateDownloadProgress(jobId: jobId, receivedBytes: received, totalBytes: total)
                        }
                    }
                )

                logger.info("[TranscriptionSheet] Cache download finished for track \(track.id.uuidString, privacy: .public); local file \(audioURL.lastPathComponent, privacy: .public)")

                // Start transcription
                await setStage(.uploading, reason: "Cache resolved; starting Soniox upload")
                await MainActor.run {
                    downloadedBytes = track.fileSize
                    totalBytes = track.fileSize
                }

                let existingJobId = await MainActor.run { downloadJobId ?? mirroredJobId }
                logger.info("[TranscriptionSheet] Handing upload to TranscriptionManager job=\(existingJobId ?? "nil", privacy: .public)")

                try await transcriptionManager.transcribeTrack(
                    trackId: track.id,
                    collectionId: collectionID,
                    audioFileURL: audioURL,
                    languageHints: ["zh", "en"],
                    context: contextText,
                    existingJobId: existingJobId
                )

                // Success
                await MainActor.run {
                    isTranscribing = false
                    progress = 1.0
                    transcriptionCompleted = true
                    setStage(.completed, reason: "TranscriptionManager finished successfully")
                }

                // Post notification for UI to refresh transcript status
                NotificationCenter.default.post(
                    name: NSNotification.Name("TranscriptionCompleted"),
                    object: nil,
                    userInfo: ["trackId": track.id.uuidString, "collectionId": collectionID.uuidString]
                )

                logger.info("[TranscriptionSheet] Posted TranscriptionCompleted notification for track \(track.id.uuidString, privacy: .public)")

                // Auto-dismiss after 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    downloadJobId = nil
                    dismiss()
                }
            } catch {
                logger.error("[TranscriptionSheet] Transcription failed for track \(track.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    isTranscribing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }

        // Monitor progress from TranscriptionManager
        Task {
            while await MainActor.run(body: { isTranscribing }) {
                await MainActor.run {
                    let managerProgress = transcriptionManager.transcriptionProgress
                    let updated = max(progress, managerProgress)
                    if updated != progress {
                        logger.debug("[TranscriptionSheet] Manager progress advanced to \(managerProgress, privacy: .public)")
                        progress = updated
                    }
                    if managerProgress >= 0.25 {
                        setStage(.transcribing, reason: "Manager progress crossed 25% (\(managerProgress))")
                    }
                    if managerProgress >= 0.9 {
                        setStage(.processing, reason: "Manager progress crossed 90% (\(managerProgress))")
                    }
                    if managerProgress >= 0.98 {
                        setStage(.finalizing, reason: "Manager progress crossed 98% (\(managerProgress))")
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }

        // Mirror job status for stage detail
        Task {
            while await MainActor.run(body: { isTranscribing }) {
                let job = await MainActor.run {
                    transcriptionManager.activeJobs.first(where: { $0.trackId == track.id.uuidString })
                }
                if let job {
                    await MainActor.run {
                        let inferredStage = Stage(jobStatus: job.status)
                        if inferredStage != .idle {
                            setStage(inferredStage, reason: "Mirroring job \(job.id) status=\(job.status)")
                        }
                        if let jobProgress = job.progress {
                            progress = max(progress, jobProgress)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func getAudioFileURL(
        track: AudiobookTrack,
        token: BaiduOAuthToken?,
        progressHandler: @escaping (Int64, Int64) async -> Void = { _,_ in }
    ) async throws -> URL {
        switch track.location {
        case let .baidu(fsId, path):
            guard let token else {
                throw TranscriptionManager.TranscriptionError.missingBaiduToken
            }

            let cacheManager = AudioCacheManager()
            let baiduFileId = String(fsId)

            if let cachedURL = cacheManager.getCachedAssetURL(
                for: track.id.uuidString,
                baiduFileId: baiduFileId,
                filename: track.filename
            ) {
                return cachedURL
            }

            let (url, _) = try await downloadBaiduAsset(
                track: track,
                path: path,
                fsId: fsId,
                token: token,
                progressHandler: progressHandler
            )
            return url

        case let .local(bookmark):
            return try resolveLocalBookmark(bookmark)

        case let .external(url):
            if url.isFileURL {
                return url
            }
            let (url, _) = try await downloadExternalAsset(track: track, url: url, progressHandler: progressHandler)
            return url
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(NSLocalizedString("transcription_context_field_label", comment: ""))
                    .font(.subheadline)
                Spacer()
                Text(NSLocalizedString("transcription_context_info", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $contextText)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )

                if contextText.isEmpty {
                    Text(NSLocalizedString("transcription_context_placeholder", comment: ""))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var processTimeline: some View {
        VStack(spacing: 8) {
            timelineRow(label: NSLocalizedString("transcription_step_downloading", comment: ""), isActive: stage == .downloading || stage == .uploading || stage == .transcribing || stage == .processing || stage == .finalizing || stage == .completed)
            timelineRow(label: NSLocalizedString("transcription_step_uploading", comment: ""), isActive: stage == .uploading || stage == .transcribing || stage == .processing || stage == .finalizing || stage == .completed)
            timelineRow(label: NSLocalizedString("transcription_step_transcribing", comment: ""), isActive: stage == .transcribing || stage == .processing || stage == .finalizing || stage == .completed)
            timelineRow(label: NSLocalizedString("transcription_step_processing", comment: ""), isActive: stage == .processing || stage == .finalizing || stage == .completed)
        }
    }

    private func timelineRow(label: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.blue : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer()
        }
    }

    private func buildDefaultContext() -> String {
        let descriptionText = collectionDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? NSLocalizedString("transcription_context_no_description", comment: "")

        return [
            "Collection: \(collectionTitle)",
            "Description: \(descriptionText)",
            "Track: \(track.displayName)"
        ].joined(separator: "\n")
    }

    private func downloadBaiduAsset(
        track: AudiobookTrack,
        path: String,
        fsId: Int64,
        token: BaiduOAuthToken,
        progressHandler: @escaping (Int64, Int64) async -> Void
    ) async throws -> (URL, Int64) {
        let cacheManager = AudioCacheManager()
        let baiduFileId = String(fsId)
        let netdiskClient = BaiduNetdiskClient()
        let downloadURL = try netdiskClient.downloadURL(forPath: path, token: token)

        // If already cached (complete), use it directly
        if let cached = cacheManager.getCachedAssetURL(
            for: track.id.uuidString,
            baiduFileId: baiduFileId,
            filename: track.filename
        ) {
            print("[Transcription] Cache hit for track \(track.id) fsId=\(fsId) -> \(cached.lastPathComponent)")
            return (cached, track.fileSize)
        }

        print("[Transcription] Cache miss for track \(track.id) fsId=\(fsId); starting cache download")

        // Otherwise download via the cache download manager (same fast path as playback)
        let cacheURL = cacheManager.createCacheFile(
            trackId: track.id.uuidString,
            baiduFileId: baiduFileId,
            filename: track.filename,
            fileSizeBytes: Int(track.fileSize)
        )

        let downloadManager = AudioCacheDownloadManager(cacheManager: cacheManager)
        let downloadedURL = try await downloadManager.downloadOnce(
            trackId: track.id.uuidString,
            baiduFileId: baiduFileId,
            filename: track.filename,
            streamingURL: downloadURL,
            cacheSizeBytes: Int(track.fileSize)
        ) { progress in
            let received = Int64(progress.downloadedRange.end)
            let total = Int64(progress.totalBytes)
            Task { await progressHandler(received, total) }
        }

        print("[Transcription] Cache download complete for track \(track.id) fsId=\(fsId) -> \(downloadedURL.lastPathComponent)")

        cacheManager.markCacheAsComplete(trackId: track.id.uuidString, baiduFileId: baiduFileId)

        return (downloadedURL, track.fileSize)
    }

    private func resolveLocalBookmark(_ bookmark: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            throw TranscriptionManager.TranscriptionError.invalidAudioFile
        }

        return url
    }

    private func downloadExternalAsset(
        track: AudiobookTrack,
        url: URL,
        progressHandler: @escaping (Int64, Int64) async -> Void
    ) async throws -> (URL, Int64) {
        return try await downloadFile(
            from: url,
            destinationURL: nil,
            suggestedFilename: track.id.uuidString + "_remote_\(track.filename)",
            fallbackTotalBytes: track.fileSize,
            progressHandler: progressHandler
        )
    }

    private func downloadFile(
        from url: URL,
        destinationURL: URL?,
        suggestedFilename: String,
        fallbackTotalBytes: Int64,
        progressHandler: @escaping (Int64, Int64) async -> Void
    ) async throws -> (URL, Int64) {
        let tempFile: URL
        if let destinationURL {
            tempFile = destinationURL
            try? FileManager.default.removeItem(at: tempFile)
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            tempFile = tempDir.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: tempFile)
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: tempFile)
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let resolvedTotal = response.expectedContentLength > 0 ? response.expectedContentLength : (fallbackTotalBytes > 0 ? fallbackTotalBytes : 0)

        var received: Int64 = 0
        var buffer = Data()
        let chunkSize = 64 * 1024
        buffer.reserveCapacity(chunkSize)
        var lastReported: Int64 = 0
        var lastReportTime = Date()

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            let bytesDelta = received - lastReported
            let timeDelta = Date().timeIntervalSince(lastReportTime)
            if bytesDelta >= Int64(chunkSize) || timeDelta >= 0.2 {
                lastReported = received
                lastReportTime = Date()
                let totalForProgress = resolvedTotal > 0 ? resolvedTotal : max(fallbackTotalBytes, received)
                await progressHandler(received, totalForProgress)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        if received != lastReported {
            let totalForProgress = resolvedTotal > 0 ? resolvedTotal : max(fallbackTotalBytes, received)
            await progressHandler(received, totalForProgress)
        }

        return (tempFile, resolvedTotal)
    }
}

extension TranscriptionSheet {
    @MainActor
    private func mirrorExistingJobIfNeeded() {
        guard let job = transcriptionManager.activeJobs.first(where: { $0.trackId == track.id.uuidString }) else {
            if mirroredJobId != nil && !isTranscribing {
                setStage(.idle, reason: "Detached from job; active job disappeared")
                progress = 0.0
                downloadedBytes = 0
                logger.info("[TranscriptionSheet] Cleared mirrored job for track \(track.id.uuidString, privacy: .public)")
            }
            mirroredJobId = nil
            downloadJobId = nil
            return
        }

        if job.id != mirroredJobId {
            logger.info("[TranscriptionSheet] Now mirroring job \(job.id, privacy: .public) status=\(job.status, privacy: .public) progress=\(job.progress ?? -1)")
        }

        mirroredJobId = job.id
        downloadJobId = job.id
        totalBytes = max(track.fileSize, 0)
        let newStage = Stage(jobStatus: job.status)
        setStage(newStage, reason: "MirrorExistingJob refresh (status=\(job.status))")
        let jobProgress = job.progress ?? defaultProgress(for: newStage)
        progress = max(progress, jobProgress)

        if newStage == .downloading {
            let computed = Int64(Double(totalBytes) * jobProgress)
            if computed > downloadedBytes {
                downloadedBytes = computed
            }
        } else if newStage == .uploading {
            downloadedBytes = totalBytes
        }

        if !isTranscribing {
            isTranscribing = true
            transcriptionCompleted = false
        }
    }

    private func defaultProgress(for stage: Stage) -> Double {
        switch stage {
        case .downloading:
            return 0.1
        case .uploading:
            return 0.2
        case .transcribing:
            return 0.6
        case .processing:
            return 0.85
        case .finalizing:
            return 0.95
        case .completed:
            return 1.0
        case .idle:
            return 0.0
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    let sampleTrack = AudiobookTrack(
        id: UUID(),
        displayName: "Sample Audio",
        filename: "sample_audio.mp3",
        location: .baidu(fsId: 12345, path: "/audiobooks/sample_audio.mp3"),
        fileSize: 5_242_880,
        duration: 320,
        trackNumber: 1,
        checksum: nil,
        metadata: [:]
    )

    TranscriptionSheet(
        track: sampleTrack,
        collectionID: UUID(),
        collectionTitle: "Sample Collection",
        collectionDescription: "Description"
    )
    .environmentObject(TranscriptionManager())
    .environmentObject(BaiduAuthViewModel())
}
