import SwiftUI
import Combine

private enum Constants {
    static let defaultNormalizedX: Double = 0.9
    static let defaultNormalizedY: Double = 0.85
}

@MainActor
class FloatingPlaybackBubbleViewModel: ObservableObject {
    @AppStorage("floatingBubblePositionNormalizedX") private var normalizedX: Double = Constants.defaultNormalizedX
    @AppStorage("floatingBubblePositionNormalizedY") private var normalizedY: Double = Constants.defaultNormalizedY

    @Published var position: CGPoint
    @Published private(set) var requiresFullScreenHitTesting: Bool = false
    
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
    
    init() {
        let screen = UIScreen.main.bounds
        let initialX = screen.width * CGFloat(Self.storedNormalizedX)
        let initialY = screen.height * CGFloat(Self.storedNormalizedY)
        self.position = CGPoint(x: initialX, y: initialY)
    }
    
    func updatePosition(_ newPosition: CGPoint) {
        self.position = newPosition
        persistPosition(newPosition)
    }
    
    func snapToEdge(in geometry: GeometryProxy) {
        let screenWidth = geometry.size.width
        let safeArea = geometry.safeAreaInsets

        // Calculate horizontal snap bounds
        let minX = safeArea.leading + padding + bubbleSize/2
        let maxX = screenWidth - safeArea.trailing - padding - bubbleSize/2

        // Determine horizontal snap target
        let targetX = position.x < screenWidth / 2 ? minX : maxX

        // Clamp Y to visible safe area (including padding)
        let minY = safeArea.top + padding + bubbleSize/2
        let maxY = geometry.size.height - safeArea.bottom - padding - bubbleSize/2
        let targetY = min(max(position.y, minY), maxY)

        let snappedPoint = CGPoint(x: targetX, y: targetY)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            self.position = snappedPoint
        }
        persistPosition(snappedPoint)
    }

    func ensurePositionWithinBounds(in geometry: GeometryProxy) {
        let minX = geometry.safeAreaInsets.leading + padding + bubbleSize/2
        let maxX = geometry.size.width - geometry.safeAreaInsets.trailing - padding - bubbleSize/2
        let minY = geometry.safeAreaInsets.top + padding + bubbleSize/2
        let maxY = geometry.size.height - geometry.safeAreaInsets.bottom - padding - bubbleSize/2

        let clampedX = min(max(position.x, minX), maxX)
        let clampedY = min(max(position.y, minY), maxY)

        if clampedX != position.x || clampedY != position.y {
            position = CGPoint(x: clampedX, y: clampedY)
            persistPosition(position)
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

    func setFullScreenHitTestingRequired(_ required: Bool) {
        requiresFullScreenHitTesting = required
    }

    private func persistPosition(_ point: CGPoint) {
        let screen = UIScreen.main.bounds
        guard screen.width > 0, screen.height > 0 else { return }
        normalizedX = Double(min(max(point.x / screen.width, 0), 1))
        normalizedY = Double(min(max(point.y / screen.height, 0), 1))
    }

    private static let defaultNormalizedX: Double = 0.9
    private static let defaultNormalizedY: Double = 0.85

    private static var storedNormalizedX: Double {
        let stored = UserDefaults.standard.object(forKey: "floatingBubblePositionNormalizedX") as? Double
        return stored ?? Constants.defaultNormalizedX
    }

    private static var storedNormalizedY: Double {
        let stored = UserDefaults.standard.object(forKey: "floatingBubblePositionNormalizedY") as? Double
        return stored ?? Constants.defaultNormalizedY
    }
}
