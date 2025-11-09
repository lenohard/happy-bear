import SwiftUI

/// Sheet for transcribing a single track
struct TranscriptionSheet: View {
    let track: AudiobookTrack
    let collectionID: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var isTranscribing = false
    @State private var progress: Double = 0.0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var transcriptionCompleted = false

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

                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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
        }
    }

    private var statusMessage: String {
        if progress < 0.2 {
            return NSLocalizedString("uploading_audio_file", comment: "Uploading audio file")
        } else if progress < 0.3 {
            return NSLocalizedString("creating_transcription_job", comment: "Creating transcription job")
        } else if progress < 0.9 {
            return NSLocalizedString("transcribing_audio", comment: "Transcribing audio")
        } else {
            return NSLocalizedString("finalizing_transcript", comment: "Finalizing transcript")
        }
    }

    private func startTranscription() {
        isTranscribing = true
        progress = 0.0
        errorMessage = nil
        transcriptionCompleted = false

        Task {
            do {
                // Resolve a local URL that can be uploaded to Soniox
                let audioURL = try await getAudioFileURL(
                    track: track,
                    token: authViewModel.token
                )

                // Start transcription
                try await transcriptionManager.transcribeTrack(
                    trackId: track.id,
                    collectionId: collectionID,
                    audioFileURL: audioURL,
                    languageHints: ["zh", "en"],
                    context: track.displayName
                )

                // Success
                await MainActor.run {
                    isTranscribing = false
                    progress = 1.0
                    transcriptionCompleted = true
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
                    progress = transcriptionManager.transcriptionProgress
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }
    }

    private func getAudioFileURL(track: AudiobookTrack, token: BaiduOAuthToken?) async throws -> URL {
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
                token: token
            )

        case let .local(bookmark):
            return try resolveLocalBookmark(bookmark)

        case let .external(url):
            if url.isFileURL {
                return url
            }
            return try await downloadExternalAsset(track: track, url: url)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func downloadBaiduAsset(track: AudiobookTrack, path: String, token: BaiduOAuthToken) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(track.id.uuidString + "_temp_\(track.filename)")

        let netdiskClient = BaiduNetdiskClient()
        let downloadURL = try netdiskClient.downloadURL(forPath: path, token: token)
        let (localURL, _) = try await URLSession.shared.download(from: downloadURL)

        try? FileManager.default.removeItem(at: tempFile)
        try FileManager.default.moveItem(at: localURL, to: tempFile)

        return tempFile
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

    private func downloadExternalAsset(track: AudiobookTrack, url: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(track.id.uuidString + "_remote_\(track.filename)")

        let (localURL, _) = try await URLSession.shared.download(from: url)

        try? FileManager.default.removeItem(at: tempFile)
        try FileManager.default.moveItem(at: localURL, to: tempFile)

        return tempFile
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
        collectionID: UUID()
    )
    .environmentObject(TranscriptionManager())
    .environmentObject(BaiduAuthViewModel())
}
