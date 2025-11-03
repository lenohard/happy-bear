import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var baiduAuth = BaiduAuthViewModel()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(audioPlayer)
                    .environmentObject(libraryStore)
                    .environmentObject(baiduAuth)

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

// MARK: - Splash Screen

struct SplashScreenView: View {
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOpacity: Double = 1.0

    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack {
                Image(systemName: "book.circle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue, .purple]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }
        }
        .onAppear {
            // Fade in animation (0.4s)
            withAnimation(.easeIn(duration: 0.4)) {
                iconScale = 1.0
            }

            // Dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.6)) {
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

