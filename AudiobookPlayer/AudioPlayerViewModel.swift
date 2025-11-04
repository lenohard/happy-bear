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

    private var playlist: [AudiobookTrack] = []
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endPlaybackObserver: NSObjectProtocol?
    private var currentToken: BaiduOAuthToken?
    private var pendingInitialSeek: Double?
    private let netdiskClient: BaiduNetdiskClient
    private let cacheManager: AudioCacheManager
    private let downloadManager: AudioCacheDownloadManager
    private let progressTracker: CacheProgressTracker
    private var cancellables: Set<AnyCancellable> = []

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
        cacheManager: AudioCacheManager = AudioCacheManager()
    ) {
        self.netdiskClient = netdiskClient
        self.cacheManager = cacheManager
        self.downloadManager = AudioCacheDownloadManager(cacheManager: cacheManager)
        self.progressTracker = CacheProgressTracker(cacheManager: cacheManager)
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

    func play(track: AudiobookTrack, in collection: AudiobookCollection, token: BaiduOAuthToken?) {
        prepareCollection(collection)
        currentToken = token

        do {
            let url = try streamURL(for: track, token: token)
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
        } else {
            startPlaybackImmediately()
            isPlaying = true
        }
#if os(iOS)
        updateNowPlayingPlaybackRate()
#endif
    }

    func skipForward(by seconds: Double = 30) {
        skip(by: seconds)
    }

    func skipBackward(by seconds: Double = 15) {
        skip(by: -seconds)
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

    func cacheStatus(for track: AudiobookTrack) -> CacheStatusSnapshot? {
        computeCacheStatus(for: track)
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

    func reset() {
        stopPlayback(clearQueue: true)
        statusMessage = nil
        activeCollection = nil
        playlist = []
    }

    @MainActor deinit {
        removeObservers()
#if os(iOS)
        clearRemoteCommandTargets()
        resetNowPlayingInfo()
#endif
    }
}

// MARK: - Private helpers

private extension AudioPlayerViewModel {
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

        addPeriodicTimeObserver()
        observeEnd(of: playerItem)

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
#if os(iOS)
                    self.updateNowPlayingPlaybackRate()
#endif
                }
            }
            if !autoPlay {
                isPlaying = false
#if os(iOS)
                updateNowPlayingPlaybackRate()
#endif
            }
        } else if autoPlay {
            startPlaybackImmediately()
            isPlaying = true
#if os(iOS)
            updateNowPlayingPlaybackRate()
#endif
        } else {
            isPlaying = false
#if os(iOS)
            updateNowPlayingPlaybackRate()
#endif
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
#if os(iOS)
            self.updateNowPlayingElapsedTime()
#endif
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
            player.playImmediately(atRate: 1.0)
        } else {
            player.play()
        }
    }

    func stopPlayback(clearQueue: Bool) {
        if let currentTrack {
            progressTracker.stopTracking(for: currentTrack.id.uuidString)
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
        }
    }

    private enum CacheResolutionError: Error {
        case missingStreamingURL
    }

    func streamURL(for track: AudiobookTrack, token: BaiduOAuthToken?) throws -> URL {
        switch track.location {
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

            Task {
                await self.startBackgroundCaching(track: track, baiduFileId: baiduFileId, fileSize: track.fileSize)
            }

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

        if let metadata = cacheManager.metadata(for: trackId, baiduFileId: baiduFileId), metadata.cacheStatus == .complete {
            if let fileSize = metadata.fileSizeBytes {
                progressTracker.markAsComplete(for: trackId, fileSizeBytes: fileSize)
            }
            refreshActiveCacheStatus()
            return
        }

        // Create cache file
        _ = cacheManager.createCacheFile(
            trackId: trackId,
            baiduFileId: baiduFileId,
            filename: track.filename,
            durationMs: track.duration.map { Int($0 * 1000) },
            fileSizeBytes: Int(fileSize)
        )

        guard let token = currentToken else { return }

        do {
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
        updateNowPlayingPlaybackRate()
        return .success
    }

    func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard let player, isPlaying else {
            return !isPlaying ? .success : .commandFailed
        }
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackRate()
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

    func updateNowPlayingInfo() {
        guard let collection = activeCollection, let track = currentTrack else {
            resetNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayName,
            MPMediaItemPropertyAlbumTitle: collection.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
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
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func resetNowPlayingInfo() {
        nowPlayingInfo.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
#endif
private extension CMTime {
    var isNumeric: Bool {
        flags.contains(.valid) && !flags.contains(.indefinite) && seconds.isFinite
    }
}
