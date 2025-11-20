import SwiftUI
import Combine

@MainActor
class FloatingPlaybackBubbleViewModel: ObservableObject {
    // Position is relative to the center of the bubble
    @Published var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 50, y: UIScreen.main.bounds.height - 150)
    
    // Persistent setting
    @AppStorage("floatingBubbleEnabled") var isEnabled: Bool = true
    
    // Session-specific hide state
    @Published var isHiddenForSession: Bool = false
    
    // Logic to determine if we should verify visibility (e.g. not on Playing tab)
    // This will be driven by the view's .onChange logic or binding
    
    private let bubbleSize: CGFloat = 60
    private let padding: CGFloat = 12
    
    var shouldShowBubble: Bool {
        return isEnabled && !isHiddenForSession
    }
    
    func updatePosition(_ newPosition: CGPoint) {
        self.position = newPosition
    }
    
    func snapToEdge(in geometry: GeometryProxy) {
        let screenWidth = geometry.size.width
        let screenHeight = geometry.size.height
        let safeArea = geometry.safeAreaInsets
        
        // Calculate bounds
        let minX = safeArea.leading + padding + bubbleSize/2
        let maxX = screenWidth - safeArea.trailing - padding - bubbleSize/2
        
        let minY = safeArea.top + padding + bubbleSize/2
        let maxY = screenHeight - safeArea.bottom - padding - bubbleSize/2
        
        // Snap X to nearest edge
        let currentX = position.x
        let midX = screenWidth / 2
        let targetX = currentX < midX ? minX : maxX
        
        // Clamp Y to safe area
        let targetY = min(max(position.y, minY), maxY)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            self.position = CGPoint(x: targetX, y: targetY)
        }
    }
    
    func hideForSession() {
        withAnimation {
            isHiddenForSession = true
        }
    }
    
    func restoreSessionVisibility() {
        withAnimation {
            isHiddenForSession = false
        }
    }
}
