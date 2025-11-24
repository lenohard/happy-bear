import SwiftUI
import UIKit

/// A UIWindow subclass that only intercepts touches on its subviews, passing through elsewhere
private class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Get the hit view from the normal hit test
        guard let hitView = super.hitTest(point, with: event) else {
            return nil
        }
        
        // If the hit view is the root view (the hosting controller's view),
        // it means the touch is on the transparent background, so pass through
        if hitView == rootViewController?.view {
            return nil
        }
        
        // Otherwise, the touch is on an actual subview (the bubble), so handle it
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
        tabSelection: TabSelectionManager
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
        
        // Create the hosting controller with the bubble view
        let bubbleView = FloatingPlaybackBubbleView(viewModel: self.viewModel)
            .environmentObject(audioPlayer)
            .environmentObject(tabSelection)
        
        let hostingController = UIHostingController(rootView: bubbleView)
        hostingController.view.backgroundColor = .clear
        
        window.rootViewController = hostingController
        window.isHidden = false
        
        self.bubbleWindow = window
    }
    
    func hide() {
        bubbleWindow?.isHidden = true
        bubbleWindow = nil
    }
}
