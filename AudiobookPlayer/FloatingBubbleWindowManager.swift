import SwiftUI
import UIKit

/// A UIWindow subclass that only intercepts touches on its subviews, passing through elsewhere
private class PassThroughWindow: UIWindow {
    var shouldHandleTouch: ((CGPoint) -> Bool)?

    // UIKit asks the window whether a point is inside before resolving a hit view.
    // Returning false here is what makes the event continue to windows below this
    // one; returning nil only from hitTest can still leave a transparent overlay
    // window in the event routing path on some iOS versions.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        shouldHandleTouch?(point) ?? false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard shouldHandleTouch?(point) ?? false else {
            return nil
        }

        guard let hitView = super.hitTest(point, with: event),
              hitView != rootViewController?.view else {
            return nil
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

        // Keep the bubble above the app's sheets while leaving system alerts and
        // navigation interaction in their normal UIKit window hierarchy.
        let window = PassThroughWindow(windowScene: windowScene)
        window.windowLevel = .normal + 1
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
