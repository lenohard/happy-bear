import SwiftUI
import UIKit

struct FloatingPlaybackBubbleView: View {
    @StateObject var viewModel: FloatingPlaybackBubbleViewModel
    @EnvironmentObject var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject var tabSelection: TabSelectionManager
    @AppStorage("floatingBubbleOpacity") private var storedOpacity: Double = 0.5
    
    // For drag gesture state
    @GestureState private var dragOffset: CGSize = .zero
    @State private var showingBubbleMenu = false
    
    private var bubbleOpacity: Double {
        min(max(storedOpacity, 0.2), 1.0)
    }
    
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
                        .overlay(
                            PassthroughLongPressRecognizer(minimumPressDuration: 0.45) {
                                showingBubbleMenu = true
                            }
                        )
                        .opacity(bubbleOpacity)
                }
                .onAppear {
                    // Ensure initial snap if needed, or validate position
                    viewModel.snapToEdge(in: geometry)
                }
            }
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
                        Circle().fill(Color(hex: hex) ?? .gray)
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
            Color.black.opacity(audioPlayer.isPlaying ? 0.2 : 0.35)
                .clipShape(Circle())
            Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
            
            // Progress Ring (Optional polish)
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
        }
        .allowsHitTesting(true) // Important: Enable touches for the bubble
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

private struct PassthroughLongPressRecognizer: UIViewRepresentable {
    var minimumPressDuration: TimeInterval
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        recognizer.minimumPressDuration = minimumPressDuration
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began {
                action()
            }
        }
    }
}
