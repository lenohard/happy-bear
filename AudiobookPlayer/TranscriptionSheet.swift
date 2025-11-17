import SwiftUI

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
            }
        }
    }

    private var statusMessage: String {
        NSLocalizedString(stage.messageKey, comment: "")
    }

    private func startTranscription() {
        isTranscribing = true
        progress = 0.0
        errorMessage = nil
        transcriptionCompleted = false
        stage = .downloading
        downloadedBytes = 0
        totalBytes = max(track.fileSize, 0)

        Task {
            do {
                // Resolve a local URL that can be uploaded to Soniox
                let audioURL = try await getAudioFileURL(
                    track: track,
                    token: authViewModel.token,
                    progressHandler: { received, total in
                        await MainActor.run {
                            downloadedBytes = received
                            totalBytes = total
                            if total > 0 {
                                progress = min(0.2, max(0.05, Double(received) / Double(total) * 0.2))
                            }
                        }
                    }
                )

                // Start transcription
                stage = .uploading
                downloadedBytes = track.fileSize
                totalBytes = track.fileSize
                try await transcriptionManager.transcribeTrack(
                    trackId: track.id,
                    collectionId: collectionID,
                    audioFileURL: audioURL,
                    languageHints: ["zh", "en"],
                    context: contextText
                )

                // Success
                await MainActor.run {
                    isTranscribing = false
                    progress = 1.0
                    transcriptionCompleted = true
                    stage = .completed
                }

                // Post notification for UI to refresh transcript status
                NotificationCenter.default.post(
                    name: NSNotification.Name("TranscriptionCompleted"),
                    object: nil,
                    userInfo: ["trackId": track.id.uuidString, "collectionId": collectionID.uuidString]
                )

                print("[TranscriptionSheet] Posted TranscriptionCompleted notification for track: \(track.id)")

                // Auto-dismiss after 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isTranscribing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }

        // Monitor progress from TranscriptionManager
        Task {
            while isTranscribing {
                await MainActor.run {
                    progress = max(progress, transcriptionManager.transcriptionProgress)
                    if transcriptionManager.transcriptionProgress >= 0.25 {
                        stage = .transcribing
                    }
                    if transcriptionManager.transcriptionProgress >= 0.9 {
                        stage = .processing
                    }
                    if transcriptionManager.transcriptionProgress >= 0.98 {
                        stage = .finalizing
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }

        // Mirror job status for stage detail
        Task {
            while isTranscribing {
                if let job = transcriptionManager.activeJobs.first(where: { $0.trackId == track.id.uuidString }) {
                    await MainActor.run {
                        let inferredStage = Stage(jobStatus: job.status)
                        if inferredStage != .idle {
                            stage = inferredStage
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

            return try await downloadBaiduAsset(
                track: track,
                path: path,
                token: token,
                progressHandler: progressHandler
            )

        case let .local(bookmark):
            return try resolveLocalBookmark(bookmark)

        case let .external(url):
            if url.isFileURL {
                return url
            }
            return try await downloadExternalAsset(track: track, url: url, progressHandler: progressHandler)
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
        token: BaiduOAuthToken,
        progressHandler: @escaping (Int64, Int64) async -> Void
    ) async throws -> URL {
        let netdiskClient = BaiduNetdiskClient()
        let downloadURL = try netdiskClient.downloadURL(forPath: path, token: token)
        return try await downloadFile(
            from: downloadURL,
            suggestedFilename: track.id.uuidString + "_temp_\(track.filename)",
            fallbackTotalBytes: track.fileSize,
            progressHandler: progressHandler
        )
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
    ) async throws -> URL {
        return try await downloadFile(
            from: url,
            suggestedFilename: track.id.uuidString + "_remote_\(track.filename)",
            fallbackTotalBytes: track.fileSize,
            progressHandler: progressHandler
        )
    }

    private func downloadFile(
        from url: URL,
        suggestedFilename: String,
        fallbackTotalBytes: Int64,
        progressHandler: @escaping (Int64, Int64) async -> Void
    ) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: tempFile)
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempFile)
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : fallbackTotalBytes

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(8192)
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 8192 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            await progressHandler(received, expected)
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        return tempFile
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
