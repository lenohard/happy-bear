import AVFoundation
import Combine
import Foundation
import CryptoKit
#if os(iOS)
import MediaPlayer
private let favoriteNowPlayingInfoKey = "MPNowPlayingInfoPropertyIsLiked"
#endif

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var statusMessage: String?
    @Published private(set) var activeCollection: AudiobookCollection?
    @Published private(set) var currentTrack: AudiobookTrack?
    @Published private(set) var activeCacheStatus: CacheStatusSnapshot?
    @Published private(set) var ephemeralContext: TemporaryPlaybackContext?
    @Published var playbackRate: Double
    @Published var sleepTimerMode: SleepTimerMode = .off
    @Published var sleepTimerRemaining: TimeInterval?
    @Published var showGenerateAudioConfirmation = false
    @Published var trackToGenerateAudio: AudiobookTrack?
    @Published var isShuffleEnabled: Bool

    enum SleepTimerMode: Equatable {
        case off
        case time(TimeInterval)
        case endOfTrack
        
        var title: String {
            switch self {
            case .off: return NSLocalizedString("timer_off", comment: "Timer off")
            case .time(let duration):
                let minutes = Int(duration / 60)
                return String(format: NSLocalizedString("timer_minutes", comment: "Timer duration"), minutes)
            case .endOfTrack: return NSLocalizedString("timer_end_of_episode", comment: "Timer end of episode")
            }
        }
    }

    private var playlist: [AudiobookTrack] = []
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endPlaybackObserver: NSObjectProtocol?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var currentToken: BaiduOAuthToken?
    private var pendingInitialSeek: Double?
    private let netdiskClient: BaiduNetdiskClient
    private let cacheManager: AudioCacheManager
    private let downloadManager: AudioCacheDownloadManager
    private let progressTracker: CacheProgressTracker
    private var cancellables: Set<AnyCancellable> = []
    private let defaults: UserDefaults
    private var sleepTimer: Timer?
    private var currentSessionStartTime: Date?
    private let sessionDurationThreshold: TimeInterval = 2.0
    private weak var library: LibraryStore?

    private static let playbackRateDefaultsKey = "audio_player_playback_rate"
    private static let shuffleDefaultsKey = "audio_player_shuffle_enabled"
    static let minPlaybackRate: Double = 0.5
    static let maxPlaybackRate: Double = 3.0
    static let presetPlaybackRates: [Double] = [0.5, 0.8, 1.0, 1.25, 1.5, 2.0, 3.0]

    private static func clampPlaybackRate(_ rate: Double) -> Double {
        let clampedLower = max(rate, minPlaybackRate)
        return min(clampedLower, maxPlaybackRate)
    }

    struct CacheStatusSnapshot {
        enum State {
            case notCached
            case partiallyCached
            case fullyCached
            case local
        }

        let trackId: UUID
        let state: State
        let percentage: Double
        let cachedBytes: Int
        let totalBytes: Int?
        let cachedRanges: [AudioCacheManager.CacheMetadata.ByteRange]
        let retentionDays: Int

        var isFullyCached: Bool { state == .fullyCached || state == .local }
    }
    #if os(iOS)
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingInfo: [String: Any] = [:]
    #endif

    init(
        netdiskClient: BaiduNetdiskClient = BaiduNetdiskClient(),
        cacheManager: AudioCacheManager = AudioCacheManager(),
        defaults: UserDefaults = .standard
    ) {
        self.netdiskClient = netdiskClient
        self.cacheManager = cacheManager
        self.downloadManager = AudioCacheDownloadManager(cacheManager: cacheManager)
        self.progressTracker = CacheProgressTracker(cacheManager: cacheManager)
        self.defaults = defaults
        let savedRate = defaults.object(forKey: Self.playbackRateDefaultsKey) as? Double
        playbackRate = Self.clampPlaybackRate(savedRate ?? 1.0)
        let savedShuffle = defaults.object(forKey: Self.shuffleDefaultsKey) as? Bool ?? false
        isShuffleEnabled = savedShuffle
        configureAudioSession()
        observeCacheProgress()
#if os(iOS)
        configureRemoteCommands()
#endif
    }

    func bindLibrary(_ library: LibraryStore?) {
        self.library = library
    }

    func notifyFavoriteToggle(for trackID: UUID) {
        applyFavoriteStateChange(for: trackID)
        updateNowPlayingFavoriteState()
    }

    var hasActivePlayer: Bool {
        player != nil
    }
    
    var sharedVideoPlayer: AVPlayer? {
        player
    }

    func prepare(with url: URL) {
        stopPlayback(clearQueue: true)
        pendingInitialSeek = nil
        preparePlayer(with: url, autoPlay: false, track: nil)
        statusMessage = nil
#if os(iOS)
        updateNowPlayingInfo()
#endif
        refreshActiveCacheStatus()
    }

    func prepareCollection(
        _ collection: AudiobookCollection,
        targetedTrack: AudiobookTrack? = nil,
        preserveQueue: Bool = false
    ) {
        if !collection.isEphemeral {
            ephemeralContext = nil
        }

        let sortedTracks = collection.tracksSortedByFilename

        let selectedTrack: AudiobookTrack?
        if let currentTrack,
           let index = sortedTracks.firstIndex(where: { $0.id == currentTrack.id }) {
            selectedTrack = sortedTracks[index]
        } else if let lastPlayed = collection.lastPlayedTrackId,
                  let match = sortedTracks.first(where: { $0.id == lastPlayed }) {
            selectedTrack = match
        } else {
            selectedTrack = sortedTracks.first
        }

        let anchorTrack: AudiobookTrack?
        if let targetedTrack,
           let match = sortedTracks.first(where: { $0.id == targetedTrack.id }) {
            anchorTrack = match
        } else {
            anchorTrack = selectedTrack
        }

        if !preserveQueue || activeCollection?.id != collection.id || playlist.isEmpty {
            playlist = makePlaylist(from: sortedTracks, startingWith: anchorTrack)
        }

        activeCollection = collection
        currentTrack = selectedTrack
        refreshActiveCacheStatus()

        if let selectedTrack,
           let state = collection.playbackStates[selectedTrack.id] {
            currentTime = state.position
            if let recordedDuration = state.duration {
                duration = max(duration, recordedDuration)
            }
        } else {
            currentTime = 0
            if !isPlaying {
                duration = 0
            }
        }
#if os(iOS)
        updateNowPlayingInfo()
#endif

        if sortedTracks.isEmpty {
            statusMessage = "\"\(collection.title)\" has no audio tracks yet."
        } else if !isPlaying && currentTrack == nil {
            statusMessage = "Select a track to start playback."
        } else {
            statusMessage = nil
        }
    }

    func loadCollection(_ collection: AudiobookCollection) {
        if activeCollection?.id != collection.id {
            stopPlayback(clearQueue: true)
        }
        prepareCollection(collection)
    }

    private let edgeTTSClient = EdgeTTSClient()

    func play(
        track: AudiobookTrack,
        in collection: AudiobookCollection,
        token: BaiduOAuthToken?,
        preserveQueue: Bool = false
    ) {
        let targetedTrack = preserveQueue ? nil : track
        prepareCollection(collection, targetedTrack: targetedTrack, preserveQueue: preserveQueue)
        currentToken = token

        if let existingTrack = currentTrack, existingTrack.id != track.id {
            progressTracker.stopTracking(for: existingTrack.id.uuidString)
        }

        // Check for ebook track and missing audio
        if track.isTextTrack {
             let trackId = track.id.uuidString
             let baiduFileId = "tts"
             // Check cache
             if !cacheManager.isCached(trackId: trackId, baiduFileId: baiduFileId, filename: "tts.mp3") {
                 trackToGenerateAudio = track
                 showGenerateAudioConfirmation = true
                 return
             }
        }

        switch track.location {
        case .text(let content):
            playTextTrack(track, content: content, in: collection)
        case .cachedText(let filename):
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let content = try? String(contentsOf: url) {
                playTextTrack(track, content: content, in: collection)
            } else {
                statusMessage = "Failed to load text content for playback."
            }
        default:
            do {
                let url = try streamURL(for: track, token: token)
                startPlayback(url: url, track: track, collection: collection)
            } catch {
                statusMessage = "Playback error: \(error.localizedDescription)"
            }
        }
    }

    private func startPlayback(url: URL, track: AudiobookTrack, collection: AudiobookCollection) {
        let resumeState = collection.playbackStates[track.id]
        if let resumePosition = resumeState?.position, resumePosition > 1 {
            pendingInitialSeek = resumePosition
            currentTime = resumePosition
        } else {
            pendingInitialSeek = nil
            currentTime = 0
        }

        if let recordedDuration = resumeState?.duration {
            duration = max(duration, recordedDuration)
        }

        preparePlayer(with: url, autoPlay: true, track: track)
        currentTrack = track
        statusMessage = "Playing \"\(track.displayName)\"."
#if os(iOS)
        updateNowPlayingInfo()
#endif
        refreshActiveCacheStatus()
        
        // Auto-generate next track audio if enabled and collection is ebook
        autoGenerateNextTrackIfNeeded(currentTrack: track, collection: collection)
    }

    private func playTextTrack(_ track: AudiobookTrack, content: String, in collection: AudiobookCollection) {
        let trackId = track.id.uuidString
        let baiduFileId = "tts"
        let filename = "tts.mp3"

        // Check cache
        if let cachedURL = cacheManager.getCachedAssetURL(for: trackId, baiduFileId: baiduFileId, filename: filename) {
            startPlayback(url: cachedURL, track: track, collection: collection)
            return
        }

        // If not cached, we shouldn't be here because play() guards it.
        // But if we are, just show error or do nothing.
        statusMessage = "Audio not generated for \"\(track.displayName)\"."
    }

    func generateAudio(for track: AudiobookTrack, in collection: AudiobookCollection, autoPlay: Bool = false) {
        let trackId = track.id.uuidString
        let baiduFileId = "tts"

        // Check if already exists
        if cacheManager.isCached(trackId: trackId, baiduFileId: baiduFileId, filename: "tts.mp3") {
            statusMessage = "Audio already exists for \"\(track.displayName)\"."
            if autoPlay {
                play(track: track, in: collection, token: nil)
            }
            return
        }

        switch track.location {
        case .text(let content):
            generateAudio(for: track, content: content, in: collection, autoPlay: autoPlay)
        case .cachedText(let filename):
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let content = try? String(contentsOf: url) {
                generateAudio(for: track, content: content, in: collection, autoPlay: autoPlay)
            } else {
                statusMessage = "Failed to load text content."
            }
        default:
            break
        }
    }

    /// Resume or retry a TTS job by job ID
    /// Used for paused or failed TTS jobs
    func resumeTTSJob(jobId: String) async throws {
        guard let job = try await GRDBDatabaseManager.shared.loadTranscriptionJob(jobId: jobId) else {
            throw NSError(domain: "AudiobookPlayer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Job not found"])
        }

        guard job.sonioxJobId.hasPrefix("tts-") else {
            throw NSError(domain: "AudiobookPlayer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Not a TTS job"])
        }

        guard let trackUUID = UUID(uuidString: job.trackId),
              let (track, collectionId) = try await GRDBDatabaseManager.shared.loadTrack(id: trackUUID) else {
            throw NSError(domain: "AudiobookPlayer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Track not found"])
        }

        // Load the collection
        guard let collection = try await GRDBDatabaseManager.shared.loadCollection(id: collectionId) else {
            throw NSError(domain: "AudiobookPlayer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
        }

        // Delete the old job so we can create a new one
        try await GRDBDatabaseManager.shared.deleteTranscriptionJob(jobId: jobId)

        // Re-run generation (it will resume from temp files)
        await MainActor.run {
            generateAudio(for: track, in: collection, autoPlay: false)
        }

        // Post notification to refresh UI
        NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil)
    }

    // MARK: - TTS Generation with Resume Support

    /// Get the temporary directory for TTS generation progress
    private func ttsTempDirectory(for trackId: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_generation")
            .appendingPathComponent(trackId)
        return tempDir
    }

    /// Check how many paragraphs have been completed (for resume)
    private func getResumeIndex(tempDir: URL, totalParagraphs: Int) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tempDir.path) else { return 0 }

        var resumeIndex = 0
        for i in 0..<totalParagraphs {
            let fileURL = tempDir.appendingPathComponent("\(i).mp3")
            if fm.fileExists(atPath: fileURL.path),
               let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int,
               size > 0 {
                resumeIndex = i + 1
            } else {
                break
            }
        }
        return resumeIndex
    }

    /// Minimum character count for a paragraph to be processed individually
    /// Paragraphs shorter than this will be merged with adjacent ones
    private static let minParagraphLength = 500

    /// Maximum character count per TTS request (Edge TTS limit is around 5000)
    private static let maxParagraphLength = 3000

    /// Preprocess paragraphs: merge short ones, split long ones
    private func preprocessParagraphs(_ rawParagraphs: [String]) -> [String] {
        var result: [String] = []
        var buffer = ""

        for paragraph in rawParagraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // If buffer + current is still short, keep accumulating
            if buffer.isEmpty {
                buffer = trimmed
            } else {
                buffer += "\n\n" + trimmed
            }

            // If buffer reached minimum length, flush it
            if buffer.count >= Self.minParagraphLength {
                // Check if we need to split long text
                if buffer.count > Self.maxParagraphLength {
                    // Split by sentences for long text
                    let chunks = splitLongText(buffer)
                    result.append(contentsOf: chunks)
                } else {
                    result.append(buffer)
                }
                buffer = ""
            }
        }

        // Don't forget remaining buffer
        if !buffer.isEmpty {
            if buffer.count > Self.maxParagraphLength {
                let chunks = splitLongText(buffer)
                result.append(contentsOf: chunks)
            } else {
                result.append(buffer)
            }
        }

        return result
    }

    /// Split long text into chunks at sentence boundaries
    private func splitLongText(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""

        // Try to split at sentence endings
        let sentenceEnders: [Character] = [".", "。", "!", "！", "?", "？", "\n"]

        for char in text {
            current.append(char)

            if sentenceEnders.contains(char) && current.count >= Self.minParagraphLength {
                if current.count >= Self.maxParagraphLength {
                    // Force split if still too long
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                } else if current.count >= Self.maxParagraphLength / 2 {
                    // Good enough size, split here
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    /// Generate audio for a paragraph with retry logic
    private func generateAudioForParagraphWithRetry(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        maxRetries: Int = 3
    ) async throws -> Data {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                return try await generateAudioForParagraph(text: text, voice: voice, rate: rate, pitch: pitch)
            } catch {
                lastError = error
                print("[TTS] Attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)")

                if attempt < maxRetries {
                    // Exponential backoff: 2s, 4s (base 2s, doubles each attempt)
                    let delaySeconds = UInt64(2 * (1 << (attempt - 1)))
                    print("[TTS] Waiting \(delaySeconds)s before retry...")
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                }
            }
        }

        throw lastError ?? EdgeTTSError.connectionFailed
    }

    /// Merge all paragraph MP3 files into final audio
    private func mergeAudioFiles(tempDir: URL, count: Int) throws -> Data {
        var combinedData = Data()
        for i in 0..<count {
            let fileURL = tempDir.appendingPathComponent("\(i).mp3")
            let data = try Data(contentsOf: fileURL)
            combinedData.append(data)
        }
        return combinedData
    }

    /// Clean up temporary TTS generation files
    private func cleanupTTSTempDirectory(for trackId: String) {
        let tempDir = ttsTempDirectory(for: trackId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func generateAudio(for track: AudiobookTrack, content: String, in collection: AudiobookCollection, autoPlay: Bool) {
        let trackId = track.id.uuidString
        let sonioxJobId = "tts-\(UUID().uuidString)"

        Task {
            do {
                // Check for existing active TTS job for this track
                if let existingJob = try? await GRDBDatabaseManager.shared.loadActiveTTSJob(forTrackId: trackId) {
                    print("[TTS] Found existing active job \(existingJob.id) for track \(trackId) with status \(existingJob.status)")
                    await MainActor.run {
                        statusMessage = "Audio generation already in progress for \"\(track.displayName)\"."
                    }
                    return
                }

                // 1. Split content into paragraphs and preprocess (merge short, split long)
                let rawParagraphs = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let paragraphs = preprocessParagraphs(rawParagraphs)
                let totalParagraphs = paragraphs.count

                print("[TTS] Preprocessed \(rawParagraphs.count) raw paragraphs into \(totalParagraphs) chunks")

                // 2. Setup temp directory for incremental saves
                let tempDir = ttsTempDirectory(for: trackId)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // 3. Check for resume point
                let resumeIndex = getResumeIndex(tempDir: tempDir, totalParagraphs: totalParagraphs)
                let isResuming = resumeIndex > 0

                if isResuming {
                    print("[TTS] Resuming from paragraph \(resumeIndex) of \(totalParagraphs)")
                }

                // Create Job
                let job = try await GRDBDatabaseManager.shared.createTranscriptionJob(
                    trackId: trackId,
                    sonioxJobId: sonioxJobId,
                    status: "queued",
                    progress: Double(resumeIndex) / Double(totalParagraphs),
                    totalParagraphs: totalParagraphs,
                    processedParagraphs: resumeIndex
                )
                let dbJobId = job.id

                await MainActor.run {
                    if isResuming {
                        statusMessage = "Resuming audio generation for \"\(track.displayName)\" from paragraph \(resumeIndex)..."
                    } else {
                        statusMessage = "Starting audio generation for \"\(track.displayName)\"..."
                    }
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil, userInfo: ["jobId": dbJobId])
                }

                // Update to processing
                try await GRDBDatabaseManager.shared.updateJobStatus(jobId: dbJobId, status: "processing", progress: Double(resumeIndex) / Double(totalParagraphs))

                let voice = defaults.string(forKey: "edge_tts_voice") ?? "en-US-AriaNeural"
                let rate = defaults.string(forKey: "edge_tts_rate") ?? "+0%"
                let pitch = defaults.string(forKey: "edge_tts_pitch") ?? "+0Hz"

                var processedParagraphsCount = resumeIndex
                var pendingParagraphsCount = 0

                var lastUpdate = Date.distantPast
                var lastProgress = -1.0

                // 4. Process paragraphs (starting from resume point)
                for i in resumeIndex..<totalParagraphs {
                    let paragraph = paragraphs[i]
                    pendingParagraphsCount += 1

                    // Throttle initial progress update
                    let currentProgress = totalParagraphs > 0 ? Double(processedParagraphsCount) / Double(totalParagraphs) : 0
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > 1.0 || abs(currentProgress - lastProgress) >= 0.05 {
                        try await GRDBDatabaseManager.shared.updateJobProgress(
                            jobId: dbJobId,
                            progress: currentProgress,
                            processedParagraphs: processedParagraphsCount,
                            totalParagraphs: totalParagraphs,
                            pendingParagraphs: pendingParagraphsCount
                        )
                        await MainActor.run {
                            NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil, userInfo: ["jobId": dbJobId])
                        }
                        lastUpdate = now
                        lastProgress = currentProgress
                    }

                    do {
                        // Generate with retry
                        let audioData = try await generateAudioForParagraphWithRetry(
                            text: paragraph,
                            voice: voice,
                            rate: rate,
                            pitch: pitch,
                            maxRetries: 3
                        )

                        // Save immediately to temp file
                        let paragraphFile = tempDir.appendingPathComponent("\(i).mp3")
                        try audioData.write(to: paragraphFile)

                        pendingParagraphsCount = max(pendingParagraphsCount - 1, 0)
                        processedParagraphsCount += 1

                        // Throttle completion progress update
                        let updatedProgress = totalParagraphs > 0 ? Double(processedParagraphsCount) / Double(totalParagraphs) : 0
                        let now2 = Date()
                        if now2.timeIntervalSince(lastUpdate) > 1.0 || abs(updatedProgress - lastProgress) >= 0.05 {
                            try await GRDBDatabaseManager.shared.updateJobProgress(
                                jobId: dbJobId,
                                progress: updatedProgress,
                                processedParagraphs: processedParagraphsCount,
                                totalParagraphs: totalParagraphs,
                                pendingParagraphs: pendingParagraphsCount
                            )
                            await MainActor.run {
                                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil, userInfo: ["jobId": dbJobId])
                            }
                            lastUpdate = now2
                            lastProgress = updatedProgress
                        }
                    } catch {
                        pendingParagraphsCount = max(pendingParagraphsCount - 1, 0)
                        let fallbackProgress = totalParagraphs > 0 ? Double(processedParagraphsCount) / Double(totalParagraphs) : 0
                        try? await GRDBDatabaseManager.shared.updateJobProgress(
                            jobId: dbJobId,
                            progress: fallbackProgress,
                            processedParagraphs: processedParagraphsCount,
                            totalParagraphs: totalParagraphs,
                            pendingParagraphs: pendingParagraphsCount
                        )
                        throw error
                    }

                    // Delay between paragraphs (1 second to avoid rate limiting)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                // 5. Merge all paragraph files into final audio
                let combinedAudioData = try mergeAudioFiles(tempDir: tempDir, count: totalParagraphs)

                // Calculate durations for transcript segments
                var transcriptSegments: [TranscriptSegment] = []
                var currentStartTimeMs = 0

                for i in 0..<totalParagraphs {
                    let paragraphFile = tempDir.appendingPathComponent("\(i).mp3")
                    let audioData = try Data(contentsOf: paragraphFile)
                    let durationMs = try getDurationMs(for: audioData)

                    let segment = TranscriptSegment(
                        transcriptId: "",
                        text: paragraphs[i],
                        startTimeMs: currentStartTimeMs,
                        endTimeMs: currentStartTimeMs + durationMs,
                        confidence: 1.0,
                        speaker: "TTS",
                        language: "en"
                    )
                    transcriptSegments.append(segment)
                    currentStartTimeMs += durationMs
                }

                // 6. Save final audio to cache
                let baiduFileId = "tts"
                let filename = "tts.mp3"
                let cacheURL = self.cacheManager.createCacheFile(
                    trackId: trackId,
                    baiduFileId: baiduFileId,
                    filename: filename,
                    durationMs: nil,
                    fileSizeBytes: combinedAudioData.count
                )

                try combinedAudioData.write(to: cacheURL)
                self.cacheManager.markCacheAsComplete(trackId: trackId, baiduFileId: baiduFileId)

                // 7. Save Transcript
                let transcriptId = UUID().uuidString
                let finalSegments = transcriptSegments.map { segment in
                    TranscriptSegment(
                        id: segment.id,
                        transcriptId: transcriptId,
                        text: segment.text,
                        startTimeMs: segment.startTimeMs,
                        endTimeMs: segment.endTimeMs,
                        confidence: segment.confidence,
                        speaker: segment.speaker,
                        language: segment.language
                    )
                }

                let transcript = Transcript(
                    id: transcriptId,
                    trackId: trackId,
                    collectionId: collection.id.uuidString,
                    language: "en",
                    fullText: content,
                    jobStatus: "complete",
                    jobId: sonioxJobId
                )

                try await GRDBDatabaseManager.shared.saveTranscript(transcript, segments: finalSegments)

                // Mark job complete
                try await GRDBDatabaseManager.shared.markJobCompleted(jobId: dbJobId)

                // 8. Clean up temp directory
                cleanupTTSTempDirectory(for: trackId)

                await MainActor.run {
                    self.statusMessage = "Audio generation complete for \"\(track.displayName)\"."
                    self.refreshActiveCacheStatus()
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil, userInfo: ["jobId": dbJobId])
                    if autoPlay {
                        self.play(track: track, in: collection, token: nil)
                    }
                }

            } catch {
                // Mark failed - but leave temp files for resume
                if let job = try? await GRDBDatabaseManager.shared.loadTranscriptionJobBySonioxId(sonioxJobId) {
                    try? await GRDBDatabaseManager.shared.markJobFailed(jobId: job.id, errorMessage: error.localizedDescription)
                    await MainActor.run {
                        NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil, userInfo: ["jobId": job.id])
                    }
                }

                await MainActor.run {
                    self.statusMessage = "Audio generation failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func generateAudioForParagraph(text: String, voice: String, rate: String, pitch: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            edgeTTSClient.generateAudio(text: text, voice: voice, rate: rate, pitch: pitch) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func getDurationMs(for audioData: Data) throws -> Int {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try audioData.write(to: tempURL)
        let player = try AVAudioPlayer(contentsOf: tempURL)
        let duration = player.duration
        try? FileManager.default.removeItem(at: tempURL)
        return Int(duration * 1000)
    }

    func playDirect(entry: BaiduNetdiskEntry, token: BaiduOAuthToken) {
        guard !entry.isDir else {
            statusMessage = "Select an audio file to start playback."
            return
        }

        let track = AudiobookTrack(
            id: UUID(),
            displayName: entry.serverFilename,
            filename: entry.serverFilename,
            location: .baidu(fsId: entry.fsId, path: entry.path),
            fileSize: entry.size,
            duration: nil,
            trackNumber: 1,
            checksum: entry.md5,
            metadata: ["baidu_path": entry.path],
            isFavorite: false,
            favoritedAt: nil
        )

        let context = TemporaryPlaybackContext(
            title: entry.serverFilename,
            sourcePath: entry.path,
            tracks: [track]
        )

        ephemeralContext = context
        prepareCollection(context.collection)
        currentToken = token

        if let existingTrack = currentTrack, existingTrack.id != track.id {
            progressTracker.stopTracking(for: existingTrack.id.uuidString)
        }

        do {
            let url = try streamURL(for: track, token: token)
            pendingInitialSeek = nil
            preparePlayer(with: url, autoPlay: true, track: track)
            currentTrack = track
            statusMessage = "Streaming \"\(track.displayName)\" from Baidu Netdisk."
#if os(iOS)
            updateNowPlayingInfo()
#endif
            refreshActiveCacheStatus()
            // Disabled auto-cache to reduce battery drain - user must manually cache via cache sheet
            // autoCacheIfPossible(track)
        } catch {
            statusMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    func playNextTrack() {
        guard
            let collection = activeCollection,
            let currentTrack,
            let index = playlist.firstIndex(where: { $0.id == currentTrack.id })
        else { return }

        let nextIndex = playlist.index(after: index)
        guard playlist.indices.contains(nextIndex) else {
            statusMessage = "Reached the end of \"\(collection.title)\"."
            isPlaying = false
            self.currentTrack = nil
#if os(iOS)
            resetNowPlayingInfo()
#endif
            return
        }

        let nextTrack = playlist[nextIndex]
        play(track: nextTrack, in: collection, token: currentToken, preserveQueue: true)
    }

    func playPreviousTrack() {
        guard
            let collection = activeCollection,
            let currentTrack,
            let index = playlist.firstIndex(where: { $0.id == currentTrack.id })
        else { return }

        guard index > playlist.startIndex else { return }

        let previousIndex = playlist.index(before: index)
        guard playlist.indices.contains(previousIndex) else { return }

        let previousTrack = playlist[previousIndex]
        play(track: previousTrack, in: collection, token: currentToken, preserveQueue: true)
    }

    func togglePlayback() {
        guard let player else {
            statusMessage = "Player is not ready. Select a track to start playback."
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
            flushListeningSession()
        } else {
            startPlaybackImmediately()
            isPlaying = true
            startListeningSession()
        }
        applyPlaybackRateToPlayer()
    }

    func skipForward(by seconds: Double = 30) {
        skip(by: seconds)
    }

    func skipBackward(by seconds: Double = 15) {
        skip(by: -seconds)
    }

    func updatePlaybackRate(_ rate: Double) {
        let clamped = Self.clampPlaybackRate(rate)
        guard playbackRate != clamped else { return }
        playbackRate = clamped
        defaults.set(clamped, forKey: Self.playbackRateDefaultsKey)
        applyPlaybackRateToPlayer()
    }

    func setShuffleEnabled(_ enabled: Bool) {
        guard isShuffleEnabled != enabled else { return }
        isShuffleEnabled = enabled
        defaults.set(enabled, forKey: Self.shuffleDefaultsKey)
        rebuildPlaylistPreservingCurrentTrack()
    }

    func setSleepTimer(_ mode: SleepTimerMode) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerMode = mode
        sleepTimerRemaining = nil

        switch mode {
        case .off:
            break
        case .time(let duration):
            sleepTimerRemaining = duration
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.handleSleepTimerTick()
            }
        case .endOfTrack:
            break
        }
    }

    private func handleSleepTimerTick() {
        guard let remaining = sleepTimerRemaining else { return }
        if remaining > 0 {
            sleepTimerRemaining = remaining - 1
        } else {
            stopPlayback(clearQueue: false)
            setSleepTimer(.off)
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        let target = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target) { [weak self] _ in
            guard let self else { return }
            self.currentTime = time
#if os(iOS)
            self.updateNowPlayingElapsedTime()
#endif
        }
    }

    func seekAndResume(to time: Double) {
        seek(to: time)
        if !isPlaying {
            startPlaybackImmediately()
            isPlaying = true
            startListeningSession()
            applyPlaybackRateToPlayer()
        }
    }

    func cacheStatus(for track: AudiobookTrack) -> CacheStatusSnapshot? {
        computeCacheStatus(for: track)
    }
    
    func isCurrentlyPlaying(track: AudiobookTrack) -> Bool {
        return currentTrack?.id == track.id && isPlaying
    }

    func cacheRetentionDays() -> Int {
        cacheManager.currentCacheRetentionDays()
    }

    func updateCacheRetention(days: Int) {
        cacheManager.updateCacheRetention(days: days)
        cacheManager.cleanupExpiredCache()
        refreshActiveCacheStatus()
    }

    func cacheSizeBytes() -> Int {
        cacheManager.getCacheSize()
    }

    func formattedCacheSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(cacheSizeBytes()))
    }

    func cacheDirectoryPath() -> String {
        cacheManager.cacheDirectoryPath()
    }

    func clearAllCache() {
        downloadManager.cancelAll()
        cacheManager.clearAllCache()
        progressTracker.resetAll()
        refreshActiveCacheStatus()
    }

    func removeCache(for track: AudiobookTrack) {
        guard let identifiers = cacheIdentifiers(for: track) else { return }
        downloadManager.cancelDownloads(for: [track.id.uuidString])
        cacheManager.removeCacheFile(trackId: identifiers.trackKey, baiduFileId: identifiers.baiduFileId, filename: track.filename)
        progressTracker.clearProgress(for: track.id.uuidString)
        progressTracker.stopTracking(for: track.id.uuidString)
        refreshActiveCacheStatus()
    }
    
    func getCollectionCacheSize(trackIds: [String]) -> Int64 {
        cacheManager.getCacheSize(for: trackIds)
    }
    
    func removeCollectionCache(trackIds: [String]) {
        downloadManager.cancelDownloads(for: trackIds)
        cacheManager.removeCache(for: trackIds)
        for trackId in trackIds {
            progressTracker.clearProgress(for: trackId)
            progressTracker.stopTracking(for: trackId)
        }
        refreshActiveCacheStatus()
    }

    private func applyPlaybackRateToPlayer() {
        if let player {
            if isPlaying {
                player.rate = Float(playbackRate)
            } else {
                player.rate = 0
            }
        }
#if os(iOS)
        updateNowPlayingPlaybackRate()
#endif
    }

    func cacheTrackIfNeeded(_ track: AudiobookTrack) {
        guard let identifiers = cacheIdentifiers(for: track) else { return }
        
        if case .baidu = track.location, currentToken == nil {
            statusMessage = "Connect Baidu Netdisk to cache audio offline."
            return
        }
        
        Task { [weak self] in
            await self?.startBackgroundCaching(track: track, baiduFileId: identifiers.baiduFileId, fileSize: track.fileSize)
        }
    }

    private func autoCacheIfPossible(_ track: AudiobookTrack) {
        guard case let .baidu(fsId, _) = track.location else { return }
        guard currentToken != nil else { return }

        Task { [weak self] in
            await self?.startBackgroundCaching(track: track, baiduFileId: String(fsId), fileSize: track.fileSize)
        }
    }

    func reset() {
        stopPlayback(clearQueue: true)
        statusMessage = nil
        activeCollection = nil
        playlist = []
    }

    private func rebuildPlaylistPreservingCurrentTrack() {
        guard let collection = activeCollection else { return }
        let sortedTracks = collection.tracksSortedByFilename
        let anchor: AudiobookTrack?
        if let currentTrack,
           let match = sortedTracks.first(where: { $0.id == currentTrack.id }) {
            anchor = match
        } else {
            anchor = sortedTracks.first
        }

        playlist = makePlaylist(from: sortedTracks, startingWith: anchor)
    }

    private func makePlaylist(from tracks: [AudiobookTrack], startingWith anchor: AudiobookTrack?) -> [AudiobookTrack] {
        guard !tracks.isEmpty else { return [] }
        guard isShuffleEnabled else { return tracks }
        guard let anchor else { return tracks.shuffled() }
        var remaining = tracks.filter { $0.id != anchor.id }
        remaining.shuffle()
        return [anchor] + remaining
    }
    
    private func autoGenerateNextTrackIfNeeded(currentTrack: AudiobookTrack, collection: AudiobookCollection) {
        // Only auto-generate for ebook collections when setting is enabled
        // Note: Default is true if key doesn't exist (matching @AppStorage default in SettingsTabView)
        let autoGenerateEnabled = defaults.object(forKey: "autoGenerateNextEbookAudio") as? Bool ?? true
        guard case .ebook = collection.source,
              autoGenerateEnabled else {
            return
        }
        
        // Find the current track in the playlist
        guard let currentIndex = playlist.firstIndex(where: { $0.id == currentTrack.id }) else {
            return
        }
        
        // Check if there's a next track
        let nextIndex = playlist.index(after: currentIndex)
        guard playlist.indices.contains(nextIndex) else {
            return
        }
        
        let nextTrack = playlist[nextIndex]
        
        // Only generate if it's a text track and doesn't have audio yet
        guard nextTrack.isTextTrack else {
            return
        }
        
        let trackId = nextTrack.id.uuidString
        let baiduFileId = "tts"
        let filename = "tts.mp3"
        
        guard !cacheManager.isCached(trackId: trackId, baiduFileId: baiduFileId, filename: filename) else {
            return
        }
        
        // Generate audio in background without auto-play
        generateAudio(for: nextTrack, in: collection, autoPlay: false)
    }

    // MARK: - Private helpers
    
    private func stableHashHex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func cacheIdentifiers(for track: AudiobookTrack) -> (trackKey: String, baiduFileId: String)? {
        let trackKey = track.id.uuidString
        
        switch track.location {
        case let .baidu(fsId, _):
            return (trackKey, String(fsId))
        case let .external(url):
            if let checksum = track.checksum, !checksum.isEmpty {
                return (trackKey, checksum)
            }
            let hash = stableHashHex(url.absoluteString)
            // Shorten to keep filenames manageable
            let shortHash = String(hash.prefix(16))
            return (trackKey, shortHash)
        case .local:
            return nil
        case .text, .cachedText:
            return nil
        }
    }

    func observeCacheProgress() {
        progressTracker.$cachedRanges
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshActiveCacheStatus()
            }
            .store(in: &cancellables)

        progressTracker.$downloadProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshActiveCacheStatus()
            }
            .store(in: &cancellables)
    }

    func refreshActiveCacheStatus() {
        guard let track = currentTrack else {
            activeCacheStatus = nil
            return
        }

        activeCacheStatus = cacheStatus(for: track)
    }

    func computeCacheStatus(for track: AudiobookTrack) -> CacheStatusSnapshot? {
        if case .local = track.location {
            let fileSize = Int(clamping: track.fileSize)
            let range = AudioCacheManager.CacheMetadata.ByteRange(start: 0, end: fileSize)
            return CacheStatusSnapshot(
                trackId: track.id,
                state: .local,
                percentage: 1.0,
                cachedBytes: fileSize,
                totalBytes: fileSize,
                cachedRanges: [range],
                retentionDays: cacheManager.currentCacheRetentionDays()
            )
        }
        
        guard let identifiers = cacheIdentifiers(for: track) else {
            // Text-based tracks or unsupported locations
            return nil
        }
        
        let trackId = track.id
        let trackKey = identifiers.trackKey
        let baiduFileId = identifiers.baiduFileId
        let totalBytesFromTrack = track.fileSize > 0 ? Int(clamping: track.fileSize) : nil
        let trackerProgress = progressTracker.progress(for: trackKey)
        
        guard let metadata = cacheManager.metadata(for: trackKey, baiduFileId: baiduFileId) else {
            if trackerProgress > 0, let total = totalBytesFromTrack {
                let cachedBytes = Int(Double(total) * trackerProgress)
                return CacheStatusSnapshot(
                    trackId: trackId,
                    state: trackerProgress >= 0.999 ? .fullyCached : .partiallyCached,
                    percentage: min(1.0, trackerProgress),
                    cachedBytes: cachedBytes,
                    totalBytes: total,
                    cachedRanges: [AudioCacheManager.CacheMetadata.ByteRange(start: 0, end: cachedBytes)],
                    retentionDays: cacheManager.currentCacheRetentionDays()
                )
            }
            
            return CacheStatusSnapshot(
                trackId: trackId,
                state: .notCached,
                percentage: 0,
                cachedBytes: 0,
                totalBytes: totalBytesFromTrack,
                cachedRanges: [],
                retentionDays: cacheManager.currentCacheRetentionDays()
            )
        }
        
        let cachedBytes = metadata.cachedRanges.reduce(0) { sum, range in
            sum + max(0, range.end - range.start)
        }
        var totalBytes = metadata.fileSizeBytes ?? totalBytesFromTrack
        var effectiveCachedBytes = cachedBytes
        
        if let total = totalBytes, total > 0 {
            let trackerBytes = Int(Double(total) * trackerProgress)
            effectiveCachedBytes = max(effectiveCachedBytes, trackerBytes)
        } else if cachedBytes == 0, trackerProgress > 0, let total = totalBytesFromTrack {
            totalBytes = total
            effectiveCachedBytes = Int(Double(total) * trackerProgress)
        }
        
        let percentage: Double
        if let totalBytes, totalBytes > 0 {
            percentage = min(1.0, Double(effectiveCachedBytes) / Double(totalBytes))
        } else {
            percentage = metadata.cacheStatus == .complete || trackerProgress >= 0.999 ? 1.0 : max(0.0, trackerProgress)
        }
        
        let state: CacheStatusSnapshot.State
        if metadata.cacheStatus == .complete || percentage >= 0.999 {
            state = .fullyCached
        } else if effectiveCachedBytes > 0 || trackerProgress > 0 {
            state = .partiallyCached
        } else {
            state = .notCached
        }
        
        return CacheStatusSnapshot(
            trackId: trackId,
            state: state,
            percentage: percentage,
            cachedBytes: effectiveCachedBytes,
            totalBytes: totalBytes,
            cachedRanges: metadata.cachedRanges,
            retentionDays: cacheManager.currentCacheRetentionDays()
        )
    }

    func configureAudioSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
            try session.setActive(true, options: [])
        } catch {
            statusMessage = "Audio session error: \(error.localizedDescription)"
        }
#endif
    }

    func preparePlayer(with url: URL, autoPlay: Bool, track: AudiobookTrack?) {
        removeObservers()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.rate = Float(playbackRate)

        observePlayerItemStatus(for: playerItem, track: track)
        validateVideoTrackIfNeeded(asset: asset, track: track)
        addPeriodicTimeObserver()
        observeEnd(of: playerItem)
        observeTimeControlStatus()

        let initialPosition = pendingInitialSeek
        if let initialPosition {
            currentTime = initialPosition
        } else {
            currentTime = 0
        }

        Task {
            do {
                let assetDuration = try await asset.load(.duration)
                duration = assetDuration.isNumeric ? assetDuration.seconds : 0
            } catch {
                statusMessage = "Failed to load duration: \(error.localizedDescription)"
            }
        }

        if let initialPosition {
            let target = CMTime(seconds: initialPosition, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                self.currentTime = initialPosition
                if autoPlay {
                    self.startPlaybackImmediately()
                    self.isPlaying = true
                    self.applyPlaybackRateToPlayer()
                    self.startListeningSession()
                }
            }
            if !autoPlay {
                isPlaying = false
                applyPlaybackRateToPlayer()
            }
        } else if autoPlay {
            startPlaybackImmediately()
            isPlaying = true
            applyPlaybackRateToPlayer()
            startListeningSession()
        } else {
            isPlaying = false
            applyPlaybackRateToPlayer()
        }

        pendingInitialSeek = nil
    }

    private func observePlayerItemStatus(for item: AVPlayerItem, track: AudiobookTrack?) {
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed {
                    self.handlePlayerItemFailure(item.error, track: track)
                }
            }
        }
    }

    private func handlePlayerItemFailure(_ error: Error?, track: AudiobookTrack?) {
        stopPlayback(clearQueue: false)
        if track?.mediaKind == .video {
            statusMessage = NSLocalizedString("video_playback_failed_error", comment: "Video playback failed message")
        } else if let error {
            statusMessage = "Playback error: \(error.localizedDescription)"
        } else {
            statusMessage = NSLocalizedString("generic_playback_failed", comment: "Generic playback failure")
        }
    }

    private func validateVideoTrackIfNeeded(asset: AVURLAsset, track: AudiobookTrack?) {
        guard track?.mediaKind == .video else { return }

        Task {
            do {
                let loadedTracks = try await asset.load(.tracks)
                let hasAudio = loadedTracks.contains { $0.mediaType == .audio }
                if !hasAudio {
                    await MainActor.run {
                        self.stopPlayback(clearQueue: false)
                        self.statusMessage = NSLocalizedString(
                            "video_missing_audio_error",
                            comment: "Video missing audio track message"
                        )
                    }
                }
            } catch {
                print("[AudioPlayer] Failed to inspect video track audio: \(error.localizedDescription)")
            }
        }
    }

    func observeEnd(of item: AVPlayerItem) {
        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackFinished()
        }
    }

    func handlePlaybackFinished() {
        flushListeningSession()
        if sleepTimerMode == .endOfTrack {
            stopPlayback(clearQueue: false)
            setSleepTimer(.off)
            return
        }

        currentTime = 0
        isPlaying = false
        pendingInitialSeek = nil

        guard
            let collection = activeCollection,
            let track = currentTrack,
            let index = playlist.firstIndex(where: { $0.id == track.id })
        else {
            return
        }

        progressTracker.stopTracking(for: track.id.uuidString)

        let nextIndex = playlist.index(after: index)
        guard playlist.indices.contains(nextIndex) else {
            statusMessage = "Finished playing \"\(collection.title)\"."
            currentTrack = nil
#if os(iOS)
            resetNowPlayingInfo()
#endif
            return
        }

        let nextTrack = playlist[nextIndex]
        
        // Auto-generate audio for the track after next if it's an ebook collection and setting is enabled
        // We call this with nextTrack so it will generate audio for the track AFTER the next one
        autoGenerateNextTrackIfNeeded(currentTrack: nextTrack, collection: collection)
        
        play(track: nextTrack, in: collection, token: currentToken, preserveQueue: true)
    }

    func addPeriodicTimeObserver() {
        guard let player else { return }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player?.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = max(self.duration, itemDuration)
            }
            // Lock screen elapsed time is automatically calculated by iOS based on playback rate
            // Only need to update on events (seek, play, pause, track change) - not continuously
        }
    }

    func removeObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        if let observer = endPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
            endPlaybackObserver = nil
        }
        
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
    }

    func skip(by delta: Double) {
        guard let player, let currentItem = player.currentItem else { return }
        let currentSeconds = player.currentTime().seconds

        let itemDuration = currentItem.duration.seconds.isFinite ? currentItem.duration.seconds : duration
        guard currentSeconds.isFinite, itemDuration.isFinite else { return }

        let clamped = max(0, min(currentSeconds + delta, itemDuration))
        seek(to: clamped)
    }

    func startPlaybackImmediately() {
        guard let player else { return }
        if player.currentItem != nil {
            player.playImmediately(atRate: Float(playbackRate))
        } else {
            player.play()
            player.rate = Float(playbackRate)
        }
    }

    func stopPlayback(clearQueue: Bool) {
        if let currentTrack {
            progressTracker.stopTracking(for: currentTrack.id.uuidString)
        }
        
        flushListeningSession()

        sleepTimer?.invalidate()
        sleepTimer = nil
        if case .time = sleepTimerMode {
            setSleepTimer(.off)
        }

        player?.pause()
        removeObservers()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        pendingInitialSeek = nil
#if os(iOS)
        resetNowPlayingInfo()
#endif

        activeCacheStatus = nil

        if clearQueue {
            currentTrack = nil
            currentToken = nil
            playlist = []
            ephemeralContext = nil
        }
    }

    private enum CacheResolutionError: Error {
        case missingStreamingURL
    }

    func streamURL(for track: AudiobookTrack, token: BaiduOAuthToken?) throws -> URL {
        switch track.location {
        case .text, .cachedText:
            throw CacheResolutionError.missingStreamingURL
        default:
            break
        }
        
        if let identifiers = cacheIdentifiers(for: track),
           let cachedURL = cacheManager.getCachedAssetURL(for: identifiers.trackKey, baiduFileId: identifiers.baiduFileId, filename: track.filename) {
            if track.fileSize > 0 {
                progressTracker.markAsComplete(for: identifiers.trackKey, fileSizeBytes: Int(clamping: track.fileSize))
            }
            refreshActiveCacheStatus()
            return cachedURL
        }
        
        switch track.location {
        case let .baidu(_, path):
            guard let token else {
                throw NSError(domain: "AudiobookPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing Baidu token for streaming."])
            }
            return try netdiskClient.downloadURL(forPath: path, token: token)
        case let .local(bookmark):
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                throw NSError(domain: "AudiobookPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local file bookmark is stale."])
            }
            return url
        case let .external(url):
            return url
        case .text, .cachedText:
            // Handled above
            throw CacheResolutionError.missingStreamingURL
        }
    }

    private func startBackgroundCaching(track: AudiobookTrack, baiduFileId: String, fileSize: Int64) async {
        let trackId = track.id.uuidString

        var existingMetadata = cacheManager.metadata(for: trackId, baiduFileId: baiduFileId)
        if let metadata = existingMetadata {
            if metadata.cacheStatus == .complete {
                if let fileSize = metadata.fileSizeBytes {
                    progressTracker.markAsComplete(for: trackId, fileSizeBytes: fileSize)
                }
                refreshActiveCacheStatus()
                return
            }

            if downloadManager.isDownloading(trackId: trackId) {
                progressTracker.startTracking(
                    for: trackId,
                    baiduFileId: baiduFileId,
                    with: downloadManager,
                    duration: Int(track.duration ?? 0)
                )
                refreshActiveCacheStatus()
                return
            }
        }

        do {
            // Reset cache metadata only when starting a new download
            if existingMetadata == nil {
                _ = cacheManager.createCacheFile(
                    trackId: trackId,
                    baiduFileId: baiduFileId,
                    filename: track.filename,
                    durationMs: track.duration.map { Int($0 * 1000) },
                    fileSizeBytes: Int(fileSize)
                )
                existingMetadata = cacheManager.metadata(for: trackId, baiduFileId: baiduFileId)
            } else {
                cacheManager.updateCacheMetadata(
                    trackId: trackId,
                    baiduFileId: baiduFileId,
                    durationMs: track.duration.map { Int($0 * 1000) },
                    fileSizeBytes: Int(fileSize)
                )
            }

            let streamingURL: URL
            if case let .baidu(_, path) = track.location {
                guard let token = currentToken else { return }
                streamingURL = try netdiskClient.downloadURL(forPath: path, token: token)
            } else if case let .external(url) = track.location {
                streamingURL = url
            } else {
                return
            }

            await downloadManager.startCaching(
                trackId: trackId,
                baiduFileId: baiduFileId,
                filename: track.filename,
                streamingURL: streamingURL,
                cacheSizeBytes: Int(fileSize)
            ) { [weak self] info in
                guard let self else { return }
                progressTracker.updateProgress(
                    for: info.trackId,
                    downloadedRange: info.downloadedRange,
                    totalBytes: info.totalBytes
                )
                if info.totalBytes == info.downloadedRange.end {
                    progressTracker.markAsComplete(for: trackId, fileSizeBytes: info.totalBytes)
                    cacheManager.updateCachedRanges(
                        trackId: trackId,
                        baiduFileId: baiduFileId,
                        ranges: progressTracker.cachedRanges[trackId] ?? [info.downloadedRange],
                        cacheStatus: .complete
                    )
                    progressTracker.stopTracking(for: trackId)
                }
                refreshActiveCacheStatus()
            }

            progressTracker.startTracking(
                for: trackId,
                baiduFileId: baiduFileId,
                with: downloadManager,
                duration: Int(track.duration ?? 0)
            )
        } catch {
            print("Failed to start background caching: \(error.localizedDescription)")
        }
    }
}

#if os(iOS)
// MARK: - UIImage Extension for Lock Screen Artwork
private extension UIImage {
    static func from(color: UIColor, size: CGSize = CGSize(width: 512, height: 512)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        guard Scanner(string: sanitized).scanHexInt64(&int) else { return nil }
        let a, r, g, b: UInt64

        switch sanitized.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }

        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

private extension AudioPlayerViewModel {
    func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = AudioPlayerViewModel.presetPlaybackRates.map { NSNumber(value: $0) }
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = NSLocalizedString("favorite_tracks_title", comment: "Favorite")
        commandCenter.likeCommand.localizedShortTitle = NSLocalizedString("favorite_short_title", value: "Favorite", comment: "Favorite short title")

        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleRemotePlayCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.playCommand, playTarget))

        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemotePauseCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.pauseCommand, pauseTarget))

        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteToggleCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.togglePlayPauseCommand, toggleTarget))

        let nextTarget = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleRemoteNextCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.nextTrackCommand, nextTarget))

        let previousTarget = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleRemotePreviousCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.previousTrackCommand, previousTarget))

        let changePositionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let changeEvent = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            return self?.handleRemoteChangePlaybackPosition(event: changeEvent) ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.changePlaybackPositionCommand, changePositionTarget))

        let changeRateTarget = commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            return self?.handleRemotePlaybackRateCommand(event: rateEvent) ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.changePlaybackRateCommand, changeRateTarget))

        let favoriteTarget = commandCenter.likeCommand.addTarget { [weak self] _ in
            return self?.handleRemoteFavoriteCommand() ?? .commandFailed
        }
        remoteCommandTargets.append((commandCenter.likeCommand, favoriteTarget))
    }

    func clearRemoteCommandTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        remoteCommandTargets.forEach { command, target in
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
    }

    func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil, !isPlaying else {
            return isPlaying ? .success : .commandFailed
        }
        startPlaybackImmediately()
        isPlaying = true
        applyPlaybackRateToPlayer()
        startListeningSession()
        return .success
    }

    func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard let player, isPlaying else {
            return !isPlaying ? .success : .commandFailed
        }
        player.pause()
        isPlaying = false
        applyPlaybackRateToPlayer()
        flushListeningSession()
        return .success
    }

    func handleRemoteToggleCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .commandFailed }
        togglePlayback()
        return .success
    }

    func handleRemoteNextCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .commandFailed }
        let previousTrack = currentTrack
        playNextTrack()
        let didAdvance = previousTrack?.id != currentTrack?.id
        return didAdvance ? .success : .noActionableNowPlayingItem
    }

    func handleRemotePreviousCommand() -> MPRemoteCommandHandlerStatus {
        guard player != nil else { return .commandFailed }
        let previousTrack = currentTrack
        playPreviousTrack()
        let didMove = previousTrack?.id != currentTrack?.id
        return didMove ? .success : .noActionableNowPlayingItem
    }

    func handleRemotePlaybackRateCommand(event: MPChangePlaybackRateCommandEvent) -> MPRemoteCommandHandlerStatus {
        updatePlaybackRate(Double(event.playbackRate))
        return .success
    }

    func handleRemoteChangePlaybackPosition(event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let player, let _ = currentTrack else { return .commandFailed }
        let requestedTime = max(0, event.positionTime)
        let playerDuration = player.currentItem?.duration.seconds
        let fallbackDuration = playerDuration?.isFinite == true ? playerDuration! : duration
        let upperBound = fallbackDuration.isFinite && fallbackDuration > 0 ? fallbackDuration : requestedTime
        let clampedTime = max(0, min(requestedTime, upperBound))

        let target = CMTime(seconds: clampedTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.currentTime = clampedTime
#if os(iOS)
            self.updateNowPlayingElapsedTime()
#endif
        }
        return .success
    }

    func handleRemoteFavoriteCommand() -> MPRemoteCommandHandlerStatus {
        guard
            let library,
            let collection = activeCollection,
            let track = currentTrack
        else {
            return .commandFailed
        }

        library.toggleFavorite(for: track.id, in: collection.id)
        notifyFavoriteToggle(for: track.id)
        return .success
    }

    func updateNowPlayingInfo() {
        guard let collection = activeCollection, let track = currentTrack else {
            resetNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayName,
            MPMediaItemPropertyAlbumTitle: collection.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate
        ]

        if let author = collection.author {
            info[MPMediaItemPropertyArtist] = author
        }

        let durationValue: Double
        if duration > 0 {
            durationValue = duration
        } else if let recorded = collection.playbackStates[track.id]?.duration {
            durationValue = recorded
        } else {
            durationValue = 0
        }

        if durationValue > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationValue
        }
#if os(iOS)
        info[favoriteNowPlayingInfoKey] = NSNumber(value: track.isFavorite)
#endif

        // Add artwork based on collection cover type
        switch collection.coverAsset.kind {
        case .solid(let colorHex):
            // Create artwork from solid color
            if let color = UIColor(hex: colorHex) {
                let image = UIImage.from(color: color)
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
            
        case .image(let relativePath):
            // Load local image file
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let imageURL = documentsPath.appendingPathComponent(relativePath)
            
            if FileManager.default.fileExists(atPath: imageURL.path),
               let imageData = try? Data(contentsOf: imageURL),
               let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
            
        case .remote(let url):
            // Handle remote images asynchronously
            loadRemoteArtwork(url: url)
        }

        nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
#if os(iOS)
        MPRemoteCommandCenter.shared().likeCommand.isActive = track.isFavorite
#endif
    }

    func updateNowPlayingElapsedTime() {
        guard !nowPlayingInfo.isEmpty else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func loadRemoteArtwork(url: URL) {
        Task {
            do {
                let imageData = try await URLSession.shared.data(from: url).0
                if let image = UIImage(data: imageData) {
                    await MainActor.run {
                        var updatedInfo = self.nowPlayingInfo
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        self.nowPlayingInfo = updatedInfo
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                    }
                }
            } catch {
                // Silently fail - artwork is optional
                print("Failed to load remote artwork: \(error)")
            }
        }
    }

    func updateNowPlayingPlaybackRate() {
        guard !nowPlayingInfo.isEmpty else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updateNowPlayingFavoriteState() {
        guard !nowPlayingInfo.isEmpty else { return }
        let isFavorite = currentTrack?.isFavorite ?? false
#if os(iOS)
        nowPlayingInfo[favoriteNowPlayingInfoKey] = NSNumber(value: isFavorite)
#endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
#if os(iOS)
        MPRemoteCommandCenter.shared().likeCommand.isActive = isFavorite
#endif
    }

    func resetNowPlayingInfo() {
        nowPlayingInfo.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#if os(iOS)
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
#endif
    }

    private func applyFavoriteStateChange(for trackID: UUID) {
        guard var current = currentTrack, current.id == trackID else { return }
        current.isFavorite.toggle()
        current.favoritedAt = current.isFavorite ? Date() : nil
        currentTrack = current

        if let playlistIndex = playlist.firstIndex(where: { $0.id == trackID }) {
            playlist[playlistIndex] = current
        }
    }
    
    // MARK: - Listening Statistics Tracking
    
    private func startListeningSession() {
        currentSessionStartTime = Date()
    }
    
    func flushListeningSession() {
        guard let startTime = currentSessionStartTime,
              let track = currentTrack,
              let collection = activeCollection else {
            currentSessionStartTime = nil
            return
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        // Only save sessions longer than threshold
        guard duration >= sessionDurationThreshold else {
            currentSessionStartTime = nil
            return
        }
        
        let statistic = ListeningStatistic(
            id: UUID(),
            trackId: track.id,
            collectionId: collection.id,
            startTime: startTime,
            endTime: endTime,
            createdAt: Date()
        )
        
        // Save asynchronously to avoid blocking playback
        Task {
            do {
                try await GRDBDatabaseManager.shared.saveListeningStatistic(statistic)
                print("[STATS] Saved listening session: \\(duration)s for track \\(track.displayName)")
            } catch {
                print("[STATS] Failed to save listening session: \\(error)")
            }
        }
        
        currentSessionStartTime = nil
    }
    
    private func observeTimeControlStatus() {
        timeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .paused:
                if self.isPlaying {
                    print("[AudioPlayer] Detected external pause, updating state")
                    self.isPlaying = false
                    self.flushListeningSession()
                    // We don't need to set rate to 0 here as pause implies it, 
                    // but we should ensure UI reflects state.
                }
            case .playing:
                if !self.isPlaying {
                    print("[AudioPlayer] Detected external play, updating state")
                    self.isPlaying = true
                    self.startListeningSession()
                }
            case .waitingToPlayAtSpecifiedRate:
                break
            @unknown default:
                break
            }
        }
    }
}

extension AudioPlayerViewModel {
    func checkpointListeningSession() {
        if isPlaying {
            flushListeningSession()
            startListeningSession()
        }
    }
}
#endif
private extension CMTime {
    var isNumeric: Bool {
        flags.contains(.valid) && !flags.contains(.indefinite) && seconds.isFinite
    }
}
