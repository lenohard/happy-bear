import SwiftUI
#if canImport(MobileVLCKit)
import MobileVLCKit

/// Custom UIView that ensures VLC drawable is properly updated on layout.
class VLCHostView: UIView {
    weak var vlcPlayer: VLCMediaPlayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-bind drawable when the view is laid out to ensure video renders
        // VLC requires drawable operations on main thread for OpenGL
        if let player = vlcPlayer, bounds.size != .zero {
            if player.drawable as? UIView !== self {
                if Thread.isMainThread {
                    player.drawable = self
                } else {
                    DispatchQueue.main.async { [weak self, weak player] in
                        guard let self = self, let player = player else { return }
                        player.drawable = self
                    }
                }
            }
        }
    }
}

/// A SwiftUI wrapper around VLCMediaPlayer for playing video formats not supported by AVPlayer (e.g., MKV).
struct VLCVideoPlayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    let isPlaying: Binding<Bool>
    let currentTime: Binding<Double>
    let duration: Binding<Double>

    init(
        player: VLCMediaPlayer,
        isPlaying: Binding<Bool> = .constant(true),
        currentTime: Binding<Double> = .constant(0),
        duration: Binding<Double> = .constant(0)
    ) {
        self.player = player
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
    }

    func makeUIView(context: Context) -> VLCHostView {
        let view = VLCHostView()
        view.backgroundColor = .black
        context.coordinator.setupPlayer(in: view, player: player)
        return view
    }

    func updateUIView(_ uiView: VLCHostView, context: Context) {
        // Ensure drawable is always properly bound when view updates
        // VLC requires drawable operations on main thread for OpenGL
        if player.drawable as? UIView !== uiView {
            if Thread.isMainThread {
                player.drawable = uiView
            } else {
                DispatchQueue.main.async { [player, weak uiView] in
                    guard let uiView = uiView else { return }
                    player.drawable = uiView
                }
            }
        }

        if isPlaying.wrappedValue && player.state != .playing {
            player.play()
        } else if !isPlaying.wrappedValue && player.state == .playing {
            player.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleUIView(_ uiView: VLCHostView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: VLCVideoPlayerView
        var player: VLCMediaPlayer?

        init(_ parent: VLCVideoPlayerView) {
            self.parent = parent
            super.init()
        }

        func setupPlayer(in view: VLCHostView, player: VLCMediaPlayer) {
            self.player = player
            view.vlcPlayer = player
            player.delegate = self
            // VLC requires drawable operations on main thread for OpenGL
            if Thread.isMainThread {
                player.drawable = view
            } else {
                DispatchQueue.main.async {
                    player.drawable = view
                }
            }

            if player.state == .stopped || player.state == .ended {
                player.play()
            }
        }

        func cleanup() {
            // Do NOT stop the player here to allow background playback (minimize)
            // Just detach the view
            // VLC requires drawable operations on main thread for OpenGL
            let playerRef = player
            let currentView = playerRef?.drawable as? VLCHostView

            let cleanupWork = {
                currentView?.vlcPlayer = nil
                playerRef?.drawable = nil
            }

            if Thread.isMainThread {
                cleanupWork()
            } else {
                DispatchQueue.main.async {
                    cleanupWork()
                }
            }

            player?.delegate = nil
            player = nil
        }

        // MARK: - VLCMediaPlayerDelegate

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            guard let player = player else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                switch player.state {
                case .playing:
                    self.parent.isPlaying.wrappedValue = true
                case .paused, .stopped, .ended:
                    self.parent.isPlaying.wrappedValue = false
                default:
                    break
                }
            }
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            guard let player = player else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // VLC time is in milliseconds
                let currentTimeMs = player.time.intValue
                let durationMs = player.media?.length.intValue ?? 0

                self.parent.currentTime.wrappedValue = Double(currentTimeMs) / 1000.0
                if durationMs > 0 {
                    self.parent.duration.wrappedValue = Double(durationMs) / 1000.0
                }
            }
        }
    }
}

/// A sheet view for VLC-based video playback with controls.
struct VLCVideoPlayerSheet: View {
    let player: VLCMediaPlayer
    let title: String
    let onMinimize: () -> Void
    let onClose: () -> Void
    let onPlayPauseToggle: () -> Void

    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false

    private var displayedTime: Double {
        isScrubbing ? scrubValue : currentTime
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoPlayerView(
                player: player,
                isPlaying: $isPlaying,
                currentTime: $currentTime,
                duration: $duration
            )
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation {
                    showControls.toggle()
                }
            }

            if showControls {
                controlsOverlay
            }
        }
        .onAppear {
            if !player.isPlaying {
                player.play()
            }
            isPlaying = player.isPlaying
        }
    }

    private var controlsOverlay: some View {
        VStack {
            // Top bar with close button and title
            HStack {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    onMinimize()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Bottom controls
            VStack(spacing: 12) {
                // Progress bar
                if duration > 0 {
                    Slider(
                        value: Binding(
                            get: { displayedTime },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...duration,
                        onEditingChanged: { editing in
                            if editing {
                                resumeAfterScrub = isPlaying
                                if isPlaying {
                                    player.pause()
                                    isPlaying = false
                                }
                                scrubValue = currentTime
                                isScrubbing = true
                            } else {
                                isScrubbing = false
                                player.time = VLCTime(int: Int32(scrubValue * 1000))
                                currentTime = scrubValue
                                if resumeAfterScrub {
                                    player.play()
                                    isPlaying = true
                                }
                            }
                        }
                    )
                    .tint(.white)

                    HStack {
                        Text(formatTime(displayedTime))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                }

                // Playback controls
                HStack(spacing: 40) {
                    Button {
                        player.jumpBackward(15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }

                    Button {
                        if isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                        isPlaying = player.isPlaying
                        onPlayPauseToggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                    }

                    Button {
                        player.jumpForward(15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                    }
                }
                .foregroundStyle(.white)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
#endif
