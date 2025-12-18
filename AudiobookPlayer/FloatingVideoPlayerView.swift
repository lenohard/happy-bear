import SwiftUI
import AVKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// A floating, draggable video player window
struct FloatingVideoPlayerView: View {
    let url: URL
    let title: String
    let requiresVLC: Bool
    let audioPlayer: AudioPlayerViewModel?
    let onDismiss: () -> Void

    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width / 2, y: 200)
    @State private var size: CGSize = CGSize(width: 300, height: 200)
    @GestureState private var dragOffset: CGSize = .zero
    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    #if canImport(MobileVLCKit)
    @State private var vlcPlayer: VLCMediaPlayer?
    #else
    @State private var vlcPlayer: Any? // Placeholder to satisfy compiler if VLC is missing
    #endif
    @State private var showControls = true
    @State private var controlsTimer: Timer?

    private let minSize = CGSize(width: 200, height: 150)
    private let maxSize = CGSize(width: UIScreen.main.bounds.width - 40, height: UIScreen.main.bounds.height - 100)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                videoPlayerView
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Invisible tappable layer to ensure taps are captured (especially over AVKit VideoPlayer)
                Color.black.opacity(0.001)
                    .onTapGesture {
                        toggleControls()
                    }

                if showControls {
                    controlsOverlay
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .position(
                x: position.x + dragOffset.width,
                y: position.y + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let newPosition = CGPoint(
                            x: position.x + value.translation.width,
                            y: position.y + value.translation.height
                        )
                        position = clampPosition(newPosition, in: geometry)
                    }
            )
            .onAppear {
                position = clampPosition(position, in: geometry)
                scheduleControlsHide()
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var videoPlayerView: some View {
        #if canImport(MobileVLCKit)
        if requiresVLC {
            VLCVideoPlayerView(
                url: url,
                isPlaying: $isPlaying,
                currentTime: $currentTime,
                duration: $duration,
                onPlayerReady: { player in
                    self.vlcPlayer = player
                }
            )
        } else if let player = audioPlayer?.sharedVideoPlayer {
            VideoPlayer(player: player)
                .disabled(true) // Prevent built-in controls
        } else {
            Color.black
        }
        #else
        if let player = audioPlayer?.sharedVideoPlayer {
            VideoPlayer(player: player)
                .disabled(true)
        } else {
            Color.black
        }
        #endif
    }

    private var controlsOverlay: some View {
        VStack {
            // Top bar with drag handle, title, and close button
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 8)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    #if canImport(MobileVLCKit)
                    vlcPlayer?.stop()
                    #endif
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 8)
            }
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Bottom controls
            if requiresVLC {
                vlcControls
            } else {
                avPlayerControls
            }
        }
    }

    @ViewBuilder
    private var vlcControls: some View {
        VStack(spacing: 8) {
            if duration > 0 {
                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            #if canImport(MobileVLCKit)
                            vlcPlayer?.time = VLCTime(int: Int32(newValue * 1000))
                            #endif
                        }
                    ),
                    in: 0...duration
                )
                .tint(.white)
                .padding(.horizontal, 12)

                HStack {
                    Text(formatTime(currentTime))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
            }

            HStack(spacing: 30) {
                Button {
                    #if canImport(MobileVLCKit)
                    vlcPlayer?.jumpBackward(15)
                    #endif
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }

                Button {
                    #if canImport(MobileVLCKit)
                    if isPlaying {
                        vlcPlayer?.pause()
                    } else {
                        vlcPlayer?.play()
                    }
                    #endif
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }

                Button {
                    #if canImport(MobileVLCKit)
                    vlcPlayer?.jumpForward(15)
                    #endif
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title3)
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var avPlayerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button {
                    audioPlayer?.skipBackward(by: 15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }

                Button {
                    audioPlayer?.togglePlayback()
                } label: {
                    Image(systemName: (audioPlayer?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }

                Button {
                    audioPlayer?.skipForward(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func toggleControls() {
        withAnimation {
            showControls.toggle()
        }
        if showControls {
            scheduleControlsHide()
        } else {
            controlsTimer?.invalidate()
        }
    }

    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation {
                showControls = false
            }
        }
    }

    private func clampPosition(_ point: CGPoint, in geometry: GeometryProxy) -> CGPoint {
        let minX = size.width / 2 + geometry.safeAreaInsets.leading + 20
        let maxX = geometry.size.width - size.width / 2 - geometry.safeAreaInsets.trailing - 20
        let minY = size.height / 2 + geometry.safeAreaInsets.top + 20
        let maxY = geometry.size.height - size.height / 2 - geometry.safeAreaInsets.bottom - 20

        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
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
