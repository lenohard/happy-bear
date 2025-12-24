import SwiftUI
import UIKit

/// A UIWindow subclass that only intercepts touches on its subviews, passing through elsewhere
private class PassThroughWindow: UIWindow {
    var shouldHandleTouch: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Get the hit view from the normal hit test
        guard let hitView = super.hitTest(point, with: event) else {
            return nil
        }
        
        // If we have a custom handler, check if we should handle this touch
        if let shouldHandle = shouldHandleTouch {
            if !shouldHandle(point) {
                return nil
            }
        } else {
            // Fallback: If the hit view is the root view (the hosting controller's view),
            // it means the touch is on the transparent background, so pass through.
            // Note: This fallback might be too aggressive if UIHostingController collapses hierarchy,
            // but the closure-based approach above is preferred.
            if hitView == rootViewController?.view {
                return nil
            }
        }
        
        return hitView
    }
}

/// Manages a separate UIWindow for the floating bubble to ensure it stays on top of all views including sheets
@MainActor
class FloatingBubbleWindowManager: ObservableObject {
    private var bubbleWindow: PassThroughWindow?
    private let viewModel: FloatingPlaybackBubbleViewModel
    
    init(viewModel: FloatingPlaybackBubbleViewModel) {
        self.viewModel = viewModel
    }
    
    func show(
        audioPlayer: AudioPlayerViewModel,
        tabSelection: TabSelectionManager,
        themeManager: ThemeManager
    ) {
        guard bubbleWindow == nil else { return }

        // Get the main window scene
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }

        // Create a new pass-through window at a higher level
        let window = PassThroughWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1 // Above sheets and alerts
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true

        // Define hit test logic: only capture touches within the bubble's frame
        window.shouldHandleTouch = { [weak self] point in
            guard let self = self else { return false }

            if self.viewModel.requiresFullScreenHitTesting {
                return true
            }
            // Bubble geometry
            let position = self.viewModel.position
            let size: CGFloat = 60
            // Add some padding for easier touch
            let touchPadding: CGFloat = 10

            let bubbleRect = CGRect(
                x: position.x - size/2 - touchPadding,
                y: position.y - size/2 - touchPadding,
                width: size + touchPadding*2,
                height: size + touchPadding*2
            )

            return bubbleRect.contains(point)
        }

        // Create the hosting controller with the bubble view
        let bubbleView = FloatingPlaybackBubbleView(viewModel: self.viewModel)
            .environmentObject(audioPlayer)
            .environmentObject(audioPlayer.playbackClock)
            .environmentObject(tabSelection)
            .environmentObject(themeManager)
            .ignoresSafeArea()

        let hostingController = UIHostingController(rootView: bubbleView)
        hostingController.view.backgroundColor = UIColor.clear

        window.rootViewController = hostingController
        window.isHidden = false

        self.bubbleWindow = window
    }
    
    func hide() {
        bubbleWindow?.isHidden = true
        bubbleWindow = nil
    }
}
