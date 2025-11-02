import AVFoundation
import Foundation

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var statusMessage: String?

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endPlaybackObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
    }

    func prepare(with url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        removeObservers()

        player = AVPlayer(playerItem: playerItem)
        addPeriodicTimeObserver()

        Task {
            do {
                let duration = try await asset.load(.duration)
                self.duration = duration.isNumeric ? duration.seconds : 0
            } catch {
                statusMessage = "Failed to load duration: \(error.localizedDescription)"
            }
        }

        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.player?.seek(to: .zero)
        }

        statusMessage = nil
    }

    func togglePlayback() {
        guard let player else {
            statusMessage = "Player is not ready. Tap \"Load Sample Audio\" first."
            return
        }

        if isPlaying {
            player.pause()
        } else {
            player.play()
        }

        isPlaying.toggle()
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
        }
    }

    func reset() {
        isPlaying = false
        currentTime = 0
        duration = 0
        statusMessage = nil
        removeObservers()
        player = nil
    }

    @MainActor deinit {
        removeObservers()
    }
}

// MARK: - Private helpers

private extension AudioPlayerViewModel {
    func configureAudioSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            statusMessage = "Audio session error: \(error.localizedDescription)"
        }
#endif
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
}

private extension CMTime {
    var isNumeric: Bool {
        flags.contains(.valid) && !flags.contains(.indefinite) && seconds.isFinite
    }
}
