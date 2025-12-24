import SwiftUI

struct FloatingPlaybackBubbleView: View {
    @StateObject var viewModel: FloatingPlaybackBubbleViewModel
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var playbackClock: PlaybackClock
    @EnvironmentObject var tabSelection: TabSelectionManager
    @EnvironmentObject var themeManager: ThemeManager
    @AppStorage("floatingBubbleOpacity") private var storedOpacity: Double = 0.8

    // For drag gesture state
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var isDragging: Bool = false
    @State private var showingBubbleMenu = false
    @State private var isInteracting: Bool = false // Track tap/drag interactions for scale feedback
    @State private var pendingSingleTapWorkItem: DispatchWorkItem?
    private let singleTapDelay: TimeInterval = 0.35

    private var bubbleOpacity: Double {
        min(max(storedOpacity, 0.2), 1.0)
    }

    var body: some View {
        GeometryReader { geometry in
            if let track = audioPlayer.currentTrack, viewModel.shouldShowBubble {
                bubbleContent(track: track)
                    .frame(width: 60, height: 60)
                    .background(
                        Group {
                            if themeManager.colors.isFestive {
                                // Christmas Ornament Style
                                ZStack {
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                gradient: Gradient(colors: [
                                                    Color(hex: "FF4D4D")!, // Bright Red
                                                    Color(hex: "8B0000")!  // Dark Red
                                                ]),
                                                center: .topLeading,
                                                startRadius: 5,
                                                endRadius: 60
                                            )
                                        )

                                    // Shine effect
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: [.white.opacity(0.4), .clear]),
                                                startPoint: .topLeading,
                                                endPoint: .center
                                            )
                                        )
                                        .padding(4)
                                        .blur(radius: 2)
                                }
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
                            } else {
                                // Standard Style
                                Circle()
                                    .fill(Color(uiColor: .systemBackground))
                                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                            }
                        }
                    )
                    .contentShape(Circle()) // Define hit area for the bubble
                    .scaleEffect(isInteracting ? 1.15 : 1.0) // iOS AssistiveTouch-style enlarge on interaction
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isInteracting)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onChanged { _ in
                                isInteracting = true
                            }
                            .onEnded { _ in
                                isInteracting = false
                                showingBubbleMenu = true
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(coordinateSpace: .global)
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onChanged { _ in
                                isInteracting = true
                            }
                            .onEnded { value in
                                isInteracting = false
                                let newPosition = CGPoint(
                                    x: viewModel.position.x + value.translation.width,
                                    y: viewModel.position.y + value.translation.height
                                )
                                viewModel.updatePosition(newPosition)
                                viewModel.snapToEdge(in: geometry)
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                handleDoubleTap()
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1)
                            .onEnded {
                                handleSingleTap()
                            }
                    )
                    .opacity(bubbleOpacity)
                    .animation(nil, value: dragOffset) // Prevent jitter during drag
                    // Apply position LAST. This places the bubble in the global coordinate space.
                    // Gestures attached before this modifier will operate on the bubble's local frame/shape.
                    .position(
                        x: viewModel.position.x + dragOffset.width,
                        y: viewModel.position.y + dragOffset.height
                    )
                    .onAppear {
                        viewModel.ensurePositionWithinBounds(in: geometry)
                    }
                    .confirmationDialog(
                        NSLocalizedString("floating_bubble_menu_title", comment: "Title for the floating bubble menu"),
                        isPresented: $showingBubbleMenu,
                        titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("open_playing_tab", comment: "Open playing tab")) {
                            tabSelection.switchToPlayingTab()
                        }
                        Button(NSLocalizedString("hide_for_session", comment: "Hide bubble for session")) {
                            viewModel.hideForSession()
                        }
                        Button(NSLocalizedString("settings_tab", comment: "Settings")) {
                            tabSelection.selectedTab = .personal
                        }
                        Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
                    }
                    .onChange(of: showingBubbleMenu) { isShowing in
                        viewModel.setFullScreenHitTestingRequired(isShowing)
                    }
            }
        }
    }

    private var progress: Double {
        guard playbackClock.duration > 0 else { return 0 }
        return min(max(playbackClock.currentTime / playbackClock.duration, 0), 1)
    }

    @ViewBuilder
    private func bubbleContent(track: AudiobookTrack) -> some View {
        ZStack {
            if !themeManager.colors.isFestive {
                // iOS-style gray background (Standard)
                Circle()
                    .fill(Color(white: 0.2))
            }

            // Progress Track
            Circle()
                .stroke(
                    themeManager.colors.isFestive ? Color.white.opacity(0.3) : Color.white.opacity(0.15),
                    lineWidth: 3
                )
                .padding(2)

            // Progress Indicator
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    themeManager.colors.isFestive ? themeManager.colors.festiveGold : Color.white,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(2)
                .animation(.linear(duration: 0.5), value: progress)

            // Play/Pause icon
            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .shadow(radius: themeManager.colors.isFestive ? 2 : 0)
        }
    }

    private func handleSingleTap() {
        isInteracting = true
        cancelPendingSingleTap()

        let workItem = DispatchWorkItem { [weak audioPlayer] in
            audioPlayer?.togglePlayback()
            pendingSingleTapWorkItem = nil
            endInteraction()
        }

        pendingSingleTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + singleTapDelay, execute: workItem)
    }

    private func handleDoubleTap() {
        isInteracting = true
        cancelPendingSingleTap()
        withAnimation {
            tabSelection.switchToPlayingTab()
        }
        endInteraction()
    }

    private func cancelPendingSingleTap() {
        pendingSingleTapWorkItem?.cancel()
        pendingSingleTapWorkItem = nil
    }

    private func endInteraction(after delay: TimeInterval = 0.1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isInteracting = false
        }
    }
}

// Helper for Hex Color
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}
