import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Manages a separate UIWindow for the floating video player to ensure it stays on top
@MainActor
class FloatingVideoWindowManager: ObservableObject {
    private var videoWindow: UIWindow?
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

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 2 // Above bubble and sheets
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true

        // Initial size and position
        let width: CGFloat = 300
        let height: CGFloat = 200
        let x = (UIScreen.main.bounds.width - width) / 2
        let y: CGFloat = 200
        window.frame = CGRect(x: x, y: y, width: width, height: height)

        let videoView = FloatingVideoPlayerView(
            url: url,
            title: title,
            requiresVLC: requiresVLC,
            audioPlayer: audioPlayer,
            onDismiss: { [weak self] in
                self?.hide()
            },
            onDrag: { [weak window] translation in
                guard let window = window else { return }
                let newOrigin = CGPoint(
                    x: window.frame.origin.x + translation.width,
                    y: window.frame.origin.y + translation.height
                )
                window.frame.origin = newOrigin
            }
        )

        let hostingController = UIHostingController(rootView: videoView)
        hostingController.view.backgroundColor = .clear

        // Ensure the hosting controller's view fills the window
        hostingController.view.frame = window.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

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
