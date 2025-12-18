import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// A UIWindow subclass that only intercepts touches on its subviews, passing through elsewhere
private class VideoPassThroughWindow: UIWindow {
    var shouldHandleTouch: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else {
            return nil
        }

        if let shouldHandle = shouldHandleTouch {
            if !shouldHandle(point) {
                return nil
            }
        } else {
            if hitView == rootViewController?.view {
                return nil
            }
        }

        return hitView
    }
}

/// Manages a separate UIWindow for the floating video player to ensure it stays on top
@MainActor
class FloatingVideoWindowManager: ObservableObject {
    private var videoWindow: VideoPassThroughWindow?
    @Published var isShowing = false

    func show(
        url: URL,
        title: String,
        requiresVLC: Bool,
        audioPlayer: AudioPlayerViewModel?
    ) {
        guard videoWindow == nil else { return }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }

        let window = VideoPassThroughWindow(windowScene: windowScene)
        window.windowLevel = .alert + 2 // Above bubble and sheets
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true

        // Always capture touches within the video window area
        window.shouldHandleTouch = { _ in true }

        let videoView = FloatingVideoPlayerView(
            url: url,
            title: title,
            requiresVLC: requiresVLC,
            audioPlayer: audioPlayer,
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hostingController = UIHostingController(rootView: videoView)
        hostingController.view.backgroundColor = UIColor.clear

        window.rootViewController = hostingController
        window.isHidden = false

        self.videoWindow = window
        self.isShowing = true
    }

    func hide() {
        videoWindow?.isHidden = true
        videoWindow = nil
        isShowing = false
    }
}
