import SwiftUI

struct TTSJobProgressSheet: View {
    let track: AudiobookTrack

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    private var job: TranscriptionJob? {
        let trackId = track.id.uuidString
        if let active = transcriptionManager.activeJobs.first(
            where: { $0.trackId == trackId && $0.sonioxJobId.hasPrefix("tts-") }
        ) {
            return active
        }
        return transcriptionManager.allRecentJobs.first(
            where: { $0.trackId == trackId && $0.sonioxJobId.hasPrefix("tts-") }
        )
    }

    private var trackCollection: AudiobookCollection? {
        library.collections.first { $0.tracks.contains(where: { $0.id == track.id }) }
    }

    private var statusText: String {
        guard let job = job else {
            return NSLocalizedString("tts_generating_audio", comment: "Status when TTS job is preparing")
        }

        switch job.status {
        case "queued":
            return NSLocalizedString("queued_status", comment: "Queued job status")
        case "downloading":
            return NSLocalizedString("downloading_status", comment: "Downloading job status")
        case "uploading":
            return NSLocalizedString("uploading_status", comment: "Uploading job status")
        case "generating", "transcribing", "processing":
            if let paragraphProgressText = paragraphProgressText {
                return paragraphProgressText
            }
            return NSLocalizedString("tts_generating_audio", comment: "Generating audio status")
        case "completed":
            return NSLocalizedString("completed_status", comment: "Completed job status")
        case "failed":
            return job.errorMessage ?? NSLocalizedString("failed_status", comment: "Failed job status")
        default:
            return job.status.capitalized
        }
    }

    private var paragraphProgressText: String? {
        guard
            let processed = job?.processedParagraphs,
            let total = job?.totalParagraphs,
            total > 0
        else {
            return nil
        }

        return String(
            format: NSLocalizedString("tts_generating_paragraph_progress", comment: "Paragraph progress for TTS job"),
            processed,
            total
        )
    }

    private var progressValue: Double {
        guard let job = job else { return 0 }
        if let progress = job.progress {
            return min(max(progress, 0), 1)
        }
        if let processed = job.processedParagraphs, let total = job.totalParagraphs, total > 0 {
            return min(max(Double(processed) / Double(total), 0), 1)
        }
        return 0
    }

    private var progressLabel: String {
        if job?.isCompleted == true {
            return NSLocalizedString("completed_status", comment: "Completed job status")
        } else if job?.status == "failed" {
            return job?.errorMessage ?? NSLocalizedString("failed_status", comment: "Failed job status")
        }
        return statusText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)

                    Text(track.displayName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    if let collection = trackCollection {
                        Text(collection.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    ProgressView(value: progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 1.5, anchor: .center)
                        .frame(height: 10)

                    VStack(spacing: 4) {
                        Text(progressLabel)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        if let paragraphText = paragraphProgressText {
                            Text(paragraphText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)

                if job?.isCompleted == true, let collection = trackCollection {
                    Button {
                        audioPlayer.play(track: track, in: collection, token: nil)
                        dismiss()
                    } label: {
                        Label("Play audio", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 20)
                }

                Spacer()
            }
            .padding(.vertical, 32)
            .navigationTitle("TTS Job Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done_button") {
                        audioPlayer.refreshActiveCacheStatus()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TTSJobProgressSheet_Previews: PreviewProvider {
    static var previews: some View {
        let sampleTrack = AudiobookTrack(
            id: UUID(),
            displayName: "Chapter 1",
            filename: "chapter1.txt",
            location: .text(content: "This is sample text."),
            fileSize: 1024,
            duration: nil,
            trackNumber: 1,
            checksum: nil,
            metadata: [:],
            isFavorite: false,
            favoritedAt: nil
        )

        TTSJobProgressSheet(track: sampleTrack)
            .environmentObject(TranscriptionManager())
            .environmentObject(LibraryStore())
            .environmentObject(AudioPlayerViewModel())
    }
}
