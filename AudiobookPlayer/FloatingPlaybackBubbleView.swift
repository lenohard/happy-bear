import SwiftUI

struct FloatingPlaybackBubbleView: View {
    @StateObject var viewModel: FloatingPlaybackBubbleViewModel
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var tabSelection: TabSelectionManager
    @AppStorage("floatingBubbleOpacity") private var storedOpacity: Double = 0.8
    
    // For drag gesture state
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var isDragging: Bool = false
    @State private var showingBubbleMenu = false
    @State private var isInteracting: Bool = false // Track tap/drag interactions for scale feedback
    
    private var bubbleOpacity: Double {
        min(max(storedOpacity, 0.2), 1.0)
    }
    
    var body: some View {
        GeometryReader { geometry in
            if let track = audioPlayer.currentTrack, viewModel.shouldShowBubble {
                bubbleContent(track: track)
                    .frame(width: 60, height: 60)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
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
                                isInteracting = true
                                withAnimation {
                                    tabSelection.switchToPlayingTab()
                                }
                                // Reset interaction state after animation
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isInteracting = false
                                }
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1)
                            .onEnded {
                                isInteracting = true
                                audioPlayer.togglePlayback()
                                // Reset interaction state after brief delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isInteracting = false
                                }
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
                        viewModel.snapToEdge(in: geometry)
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
                            tabSelection.selectedTab = .settings
                        }
                        Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
                    }
            }
        }
    }
    
    private var progress: Double {
        guard audioPlayer.duration > 0 else { return 0 }
        return min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1)
    }

    @ViewBuilder
    private func bubbleContent(track: AudiobookTrack) -> some View {
        ZStack {
            // iOS-style gray background
            Circle()
                .fill(Color(white: 0.2))
            
            // Progress Track
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)
                .padding(2)
            
            // Progress Indicator
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(2)
                .animation(.linear(duration: 0.5), value: progress)
            
            // Play/Pause icon
            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
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
