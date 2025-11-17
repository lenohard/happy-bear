import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var baiduAuth = BaiduAuthViewModel()
    @StateObject private var tabSelection = TabSelectionManager()
    @StateObject private var aiGateway = AIGatewayViewModel()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(audioPlayer)
                    .environmentObject(libraryStore)
                    .environmentObject(baiduAuth)
                    .environmentObject(tabSelection)
                    .environmentObject(aiGateway)
                    .environmentObject(transcriptionManager)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .zIndex(1)
                }
            }
        }
    }
}

// MARK: - App Delegate for Quick Actions

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        if shortcutItem.type == "com.senaca.AudiobookPlayer.continueLast" {
            NotificationCenter.default.post(name: .resumePlaybackShortcut, object: nil)
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}

extension Notification.Name {
    static let resumePlaybackShortcut = Notification.Name("resumePlaybackShortcut")
}

// MARK: - Splash Screen

struct SplashScreenView: View {
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOpacity: Double = 1.0

    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)
                            .ignoresSafeArea()

            VStack {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 120, height: 120)
                                .scaleEffect(iconScale)
                                .opacity(iconOpacity)
                        }
        }
        .onAppear {
            // Fade in animation (0.4s)
            withAnimation(.easeIn(duration: 0.5)) {
                iconScale = 1.5
            }

            // Dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.7)) {
                    iconOpacity = 0
                    onDismiss()
                }
            }
        }
    }
}

#Preview {
    SplashScreenView(onDismiss: {})
}
