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
    @StateObject private var aiGenerationManager = AIGenerationManager()
    @State private var showSplash = true
    @State private var pendingEbookURL: URL?

    @Environment(\.scenePhase) private var scenePhase

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
                    .environmentObject(aiGenerationManager)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .zIndex(1)
                }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background || newPhase == .inactive {
                    audioPlayer.checkpointListeningSession()
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .sheet(item: Binding(
                get: { pendingEbookURL.map { PendingEbookImport(url: $0) } },
                set: { pendingEbookURL = $0?.url }
            )) { ebookImport in
                CreateEbookCollectionView(
                    epubURL: ebookImport.url,
                    onComplete: { _ in
                        pendingEbookURL = nil
                    }
                )
                .environmentObject(libraryStore)
            }
        }
    }
    
    // MARK: - URL Handling
    
    private func handleIncomingURL(_ url: URL) {
        // Check if it's an EPUB file
        guard url.pathExtension.lowercased() == "epub" else {
            print("Unsupported file type: \(url.pathExtension)")
            return
        }
        
        // Prepare the EPUB file for preview
        Task {
            do {
                // For security-scoped resources (files from other apps)
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                // Copy to temporary location if needed (inbox files are temporary)
                let tempURL: URL
                if url.path.contains("Inbox") {
                    // File is in the app's Inbox (temporary), copy it
                    let tempDir = FileManager.default.temporaryDirectory
                    tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
                    
                    // Remove existing temp file if any
                    try? FileManager.default.removeItem(at: tempURL)
                    
                    // Copy the file
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    
                    // Clean up the inbox file
                    try? FileManager.default.removeItem(at: url)
                } else {
                    tempURL = url
                }
                
                // Show preview sheet and switch to library tab
                await MainActor.run {
                    pendingEbookURL = tempURL
                    tabSelection.selectedTab = .library
                }
                
                print("Prepared EPUB for preview: \(url.lastPathComponent)")
            } catch {
                print("Failed to prepare EPUB: \(error)")
            }
        }
    }
}

private struct PendingEbookImport: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
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
    static let transcriptDidFinalize = Notification.Name("transcriptDidFinalize")
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
