import SwiftUI
import AVKit

/// Reusable UIViewControllerRepresentable wrapper for AVPlayerViewController with PiP support
struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let isPresented: Binding<Bool>

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: isPresented)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            DispatchQueue.main.async {
                if self.isPresented.wrappedValue == false {
                    self.isPresented.wrappedValue = true
                }
                completionHandler(true)
            }
        }
    }
}
