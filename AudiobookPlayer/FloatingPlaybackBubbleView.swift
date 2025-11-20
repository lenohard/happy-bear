import SwiftUI

struct FloatingPlaybackBubbleView: View {
    @StateObject var viewModel: FloatingPlaybackBubbleViewModel
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var tabSelection: TabSelectionManager
    @AppStorage("floatingBubbleOpacity") private var storedOpacity: Double = 0.8
    
    // For drag gesture state
    @GestureState private var dragOffset: CGSize = .zero
    @State private var showingBubbleMenu = false
    
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
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                showingBubbleMenu = true
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(coordinateSpace: .global)
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
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
                                withAnimation {
                                    tabSelection.switchToPlayingTab()
                                }
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1)
                            .onEnded {
                                audioPlayer.togglePlayback()
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
    
    @ViewBuilder
    private func bubbleContent(track: AudiobookTrack) -> some View {
        ZStack {
            // iOS-style gray background
            Circle()
                .fill(Color(white: 0.2))
            
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
