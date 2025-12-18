import SwiftUI
#if canImport(MobileVLCKit)
import MobileVLCKit

/// A SwiftUI wrapper around VLCMediaPlayer for playing video formats not supported by AVPlayer (e.g., MKV).
struct VLCVideoPlayerView: UIViewRepresentable {
    let url: URL
    let isPlaying: Binding<Bool>
    let currentTime: Binding<Double>
    let duration: Binding<Double>
    let onPlayerReady: ((VLCMediaPlayer) -> Void)?

    init(
        url: URL,
        isPlaying: Binding<Bool> = .constant(true),
        currentTime: Binding<Double> = .constant(0),
        duration: Binding<Double> = .constant(0),
        onPlayerReady: ((VLCMediaPlayer) -> Void)? = nil
    ) {
        self.url = url
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.onPlayerReady = onPlayerReady
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.setupPlayer(in: view, url: url)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let player = context.coordinator.player
        if isPlaying.wrappedValue && player?.state != .playing {
            player?.play()
        } else if !isPlaying.wrappedValue && player?.state == .playing {
            player?.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: VLCVideoPlayerView
        var player: VLCMediaPlayer?
        private var timeObserverActive = false

        init(_ parent: VLCVideoPlayerView) {
            self.parent = parent
            super.init()
        }

        func setupPlayer(in view: UIView, url: URL) {
            let media = VLCMedia(url: url)
            let player = VLCMediaPlayer()
            player.delegate = self
            player.drawable = view
            player.media = media
            self.player = player

            // Start playback
            player.play()
            parent.onPlayerReady?(player)
        }

        func cleanup() {
            player?.stop()
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
    let url: URL
    let title: String
    let onDismiss: () -> Void

    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var player: VLCMediaPlayer?
    @State private var showControls = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoPlayerView(
                url: url,
                isPlaying: $isPlaying,
                currentTime: $currentTime,
                duration: $duration,
                onPlayerReady: { player in
                    self.player = player
                }
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
        .onDisappear {
            player?.stop()
        }
    }

    private var controlsOverlay: some View {
        VStack {
            // Top bar with close button and title
            HStack {
                Button {
                    player?.stop()
                    dismiss()
                    onDismiss()
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
                            get: { currentTime },
                            set: { newValue in
                                player?.time = VLCTime(int: Int32(newValue * 1000))
                            }
                        ),
                        in: 0...duration
                    )
                    .tint(.white)

                    HStack {
                        Text(formatTime(currentTime))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                }

                // Playback controls
                HStack(spacing: 40) {
                    Button {
                        player?.jumpBackward(15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }

                    Button {
                        if isPlaying {
                            player?.pause()
                        } else {
                            player?.play()
                        }
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                    }

                    Button {
                        player?.jumpForward(15)
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
