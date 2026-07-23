import UIKit

/// Light haptic feedback for interactive actions (favorite, queue, archive, etc.).
func hapticLight() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
}
