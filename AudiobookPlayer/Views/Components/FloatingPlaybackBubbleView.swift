import SwiftUI

struct FloatingPlaybackBubbleView: View {
    @StateObject var viewModel: FloatingPlaybackBubbleViewModel
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var tabSelection: TabSelectionManager
    
    // For drag gesture state
    @GestureState private var dragOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            if let track = audioPlayer.currentTrack, viewModel.shouldShowBubble {
                ZStack {
                    // Bubble Content
                    bubbleContent(track: track)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        )
                        .position(
                            x: viewModel.position.x + dragOffset.width,
                            y: viewModel.position.y + dragOffset.height
                        )
                        .gesture(
                            DragGesture()
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
                        .onTapGesture(count: 2) {
                            // Double tap: Open Playing Tab
                            withAnimation {
                                tabSelection.switchToPlayingTab()
                            }
                        }
                        .onTapGesture(count: 1) {
                            // Single tap: Toggle Play/Pause
                            audioPlayer.togglePlayback()
                        }
                        .contextMenu {
                            Button {
                                tabSelection.switchToPlayingTab()
                            } label: {
                                Label(NSLocalizedString("open_playing_tab", comment: "Open playing tab"), systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            
                            Button {
                                viewModel.hideForSession()
                            } label: {
                                Label(NSLocalizedString("hide_for_session", comment: "Hide bubble for session"), systemImage: "eye.slash")
                            }
                            
                            Divider()
                            
                            Button {
                                tabSelection.selectedTab = .settings
                            } label: {
                                Label(NSLocalizedString("settings_tab", comment: "Settings"), systemImage: "gear")
                            }
                        }
                }
                .onAppear {
                    // Ensure initial snap if needed, or validate position
                    viewModel.snapToEdge(in: geometry)
                }
            }
        }
        // Allow touches to pass through the empty parts of GeometryReader
        .allowsHitTesting(false) 
        // Re-enable hit testing for the bubble itself
        .overlay(
            GeometryReader { geometry in
                if let track = audioPlayer.currentTrack, viewModel.shouldShowBubble {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(false) // The background shouldn't block touches
                        .overlay(
                            // Duplicate the bubble logic here? No, that's messy.
                            // Better approach: The ZStack above is the overlay.
                            // We need to make sure the GeometryReader doesn't block touches.
                            // Standard SwiftUI trick: GeometryReader takes all space.
                            // We'll use a different approach for integration in ContentView.
                            EmptyView()
                        )
                }
            }
        )
    }
    
    @ViewBuilder
    private func bubbleContent(track: AudiobookTrack) -> some View {
        ZStack {
            // Artwork
            if let collection = audioPlayer.activeCollection {
                // Simple artwork placeholder or actual image if we had an async image loader ready
                // For now, use a solid color or system icon if no image
                Group {
                    switch collection.coverAsset.kind {
                    case .solid(let hex):
                        // Use the shared Color(hex:) extension
                        Circle().fill(Color(hexString: hex))
                    default:
                        Circle().fill(Color.gray)
                        Image(systemName: "music.note")
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Circle().fill(Color.gray)
            }
            
            // Play/Pause Overlay
            if !audioPlayer.isPlaying {
                Color.black.opacity(0.3)
                    .clipShape(Circle())
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            
            // Progress Ring (Optional polish)
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
        }
        .allowsHitTesting(true) // Important: Enable touches for the bubble
    }
}
