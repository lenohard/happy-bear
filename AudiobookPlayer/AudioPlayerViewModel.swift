import AVFoundation
import Combine
import Foundation
#if os(iOS)
import MediaPlayer
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

    private static let playbackRateDefaultsKey = "audio_player_playback_rate"
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
        configureAudioSession()
        observeCacheProgress()
#if os(iOS)
        configureRemoteCommands()
#endif
    }

    var hasActivePlayer: Bool {
        player != nil
    }

    func prepare(with url: URL) {
        stopPlayback(clearQueue: true)
        pendingInitialSeek = nil
        preparePlayer(with: url, autoPlay: false)
        statusMessage = nil
#if os(iOS)
        updateNowPlayingInfo()
#endif
        refreshActiveCacheStatus()
    }

    func prepareCollection(_ collection: AudiobookCollection) {
        if !collection.isEphemeral {
            ephemeralContext = nil
        }

        let sortedTracks = collection.tracks.sorted { lhs, rhs in
            lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }

        playlist = sortedTracks
        activeCollection = collection

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

    func play(track: AudiobookTrack, in collection: AudiobookCollection, token: BaiduOAuthToken?) {
        prepareCollection(collection)
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

        preparePlayer(with: url, autoPlay: true)
        currentTrack = track
        statusMessage = "Playing \"\(track.displayName)\"."
#if os(iOS)
        updateNowPlayingInfo()
#endif
        refreshActiveCacheStatus()
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

    private func generateAudio(for track: AudiobookTrack, content: String, in collection: AudiobookCollection, autoPlay: Bool) {
        let trackId = track.id.uuidString
        let sonioxJobId = "tts-\(UUID().uuidString)"
        
        Task {
            do {
                // 1. Split content into paragraphs
                let paragraphs = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                let totalParagraphs = paragraphs.count
                
                // Create Job
                let job = try await GRDBDatabaseManager.shared.createTranscriptionJob(
                    trackId: trackId,
                    sonioxJobId: sonioxJobId,
                    status: "queued",
                    progress: 0.0,
                    totalParagraphs: totalParagraphs,
                    processedParagraphs: 0
                )
                let dbJobId = job.id
                
                await MainActor.run {
                    statusMessage = "Starting audio generation for \"\(track.displayName)\"..."
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil)
                }
                
                // Update to processing
                try await GRDBDatabaseManager.shared.updateJobStatus(jobId: dbJobId, status: "processing", progress: 0.0)
                
                let voice = defaults.string(forKey: "edge_tts_voice") ?? "en-US-AriaNeural"
                let rate = defaults.string(forKey: "edge_tts_rate") ?? "+0%"
                let pitch = defaults.string(forKey: "edge_tts_pitch") ?? "+0Hz"
                
                var combinedAudioData = Data()
                var transcriptSegments: [TranscriptSegment] = []
                var currentStartTimeMs = 0
                
                // 2. Process paragraphs
                for (index, paragraph) in paragraphs.enumerated() {
                    // Generate audio for this paragraph
                    let audioData = try await generateAudioForParagraph(text: paragraph, voice: voice, rate: rate, pitch: pitch)
                    
                    // Calculate duration
                    let durationMs = try getDurationMs(for: audioData)
                    
                    // Create segment placeholder (will update transcriptId later)
                    let segment = TranscriptSegment(
                        transcriptId: "", 
                        text: paragraph,
                        startTimeMs: currentStartTimeMs,
                        endTimeMs: currentStartTimeMs + durationMs,
                        confidence: 1.0,
                        speaker: "TTS",
                        language: "en"
                    )
                    transcriptSegments.append(segment)
                    
                    // Update offsets
                    currentStartTimeMs += durationMs
                    combinedAudioData.append(audioData)
                    
                    // Update progress
                    let progress = Double(index + 1) / Double(totalParagraphs)
                    try await GRDBDatabaseManager.shared.updateJobProgress(
                        jobId: dbJobId,
                        progress: progress,
                        processedParagraphs: index + 1,
                        totalParagraphs: totalParagraphs
                    )
                    
                    // Small delay to be nice to the API
                    try await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                }
                
                // 3. Save final audio
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
                
                // 4. Save Transcript
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
                
                await MainActor.run {
                    self.statusMessage = "Audio generation complete for \"\(track.displayName)\"."
                    self.refreshActiveCacheStatus()
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil)
                    if autoPlay {
                        self.play(track: track, in: collection, token: nil)
                    }
                }
                
            } catch {
                // Mark failed
                if let job = try? await GRDBDatabaseManager.shared.loadTranscriptionJobBySonioxId(sonioxJobId) {
                    try? await GRDBDatabaseManager.shared.markJobFailed(jobId: job.id, errorMessage: error.localizedDescription)
                }
                
                await MainActor.run {
                    self.statusMessage = "Audio generation failed: \(error.localizedDescription)"
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionJobUpdated"), object: nil)
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
            preparePlayer(with: url, autoPlay: true)
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
        play(track: nextTrack, in: collection, token: currentToken)
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
        play(track: previousTrack, in: collection, token: currentToken)
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
        guard case let .baidu(fsId, _) = track.location else { return }
        cacheManager.removeCacheFile(trackId: track.id.uuidString, baiduFileId: String(fsId), filename: track.filename)
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
        guard case let .baidu(fsId, _) = track.location else { return }

        guard currentToken != nil else {
            statusMessage = "Connect Baidu Netdisk to cache audio offline."
            return
        }

        Task { [weak self] in
            await self?.startBackgroundCaching(track: track, baiduFileId: String(fsId), fileSize: track.fileSize)
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

    // MARK: - Private helpers

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
        switch track.location {
        case let .baidu(fsId, _):
            let trackId = track.id
            let trackKey = trackId.uuidString
            let totalBytesFromTrack = track.fileSize > 0 ? Int(clamping: track.fileSize) : nil
            let trackerProgress = progressTracker.progress(for: trackKey)

            guard let metadata = cacheManager.metadata(for: trackKey, baiduFileId: String(fsId)) else {
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
        case .local:
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
        case .external:
            return nil
        case .text, .cachedText:
            // Text-based tracks (ebooks) don't have cache status
            return nil
        }
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

    func preparePlayer(with url: URL, autoPlay: Bool) {
        removeObservers()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.rate = Float(playbackRate)

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
        play(track: nextTrack, in: collection, token: currentToken)
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
        case .text:
             // This should not be called directly if playTextTrack handles it, 
             // but for completeness or if called elsewhere:
             throw CacheResolutionError.missingStreamingURL
        case .cachedText:
             throw CacheResolutionError.missingStreamingURL
        case let .baidu(fsId, path):
            let baiduFileId = String(fsId)

            if let cachedURL = cacheManager.getCachedAssetURL(for: track.id.uuidString, baiduFileId: baiduFileId, filename: track.filename) {
                progressTracker.markAsComplete(for: track.id.uuidString, fileSizeBytes: Int(clamping: track.fileSize))
                refreshActiveCacheStatus()
                return cachedURL
            }

            guard let token else {
                throw NSError(domain: "AudiobookPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing Baidu token for streaming."])
            }

            let streamingURL = try netdiskClient.downloadURL(forPath: path, token: token)

            return streamingURL
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

        guard let token = currentToken else { return }

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

            let streamingURL = try netdiskClient.downloadURL(forPath: {
                if case let .baidu(_, path) = track.location {
                    return path
                }
                return ""
            }(), token: token)

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

    func resetNowPlayingInfo() {
        nowPlayingInfo.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
