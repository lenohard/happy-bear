import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var baiduAuth = BaiduAuthViewModel()
    @StateObject private var aliyunAuth = AliyunAuthViewModel()
    @StateObject private var tabSelection = TabSelectionManager()
    @StateObject private var aiGateway = AIGatewayViewModel()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var aiGenerationManager = AIGenerationManager()
    @StateObject private var remoteJobsStore = RemoteJobsStore()
    @StateObject private var bubbleWindowManager = FloatingBubbleWindowManager(viewModel: FloatingPlaybackBubbleViewModel())
    @StateObject private var themeManager = ThemeManager()
    @State private var showSplash = true
    @State private var pendingEbookURL: URL?

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(audioPlayer)
                    .environmentObject(audioPlayer.playbackClock)
                    .environmentObject(libraryStore)
                    .environmentObject(baiduAuth)
                    .environmentObject(aliyunAuth)
                    .environmentObject(tabSelection)
                    .environmentObject(aiGateway)
                    .environmentObject(transcriptionManager)
                    .environmentObject(aiGenerationManager)
                    .environmentObject(remoteJobsStore)
                    .environmentObject(themeManager)
                    .preferredColorScheme(themeManager.colorScheme)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .zIndex(1)
                }
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    // App became active - check for pending jobs that may have been interrupted
                    Task {
                        await transcriptionManager.checkAndResumePendingJobs()
                        await aiGenerationManager.refreshJobs()
                    }
                case .background, .inactive:
                    // App going to background - checkpoint listening session
                    audioPlayer.checkpointListeningSession()
                @unknown default:
                    break
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onReceive(IntentCoordinator.shared.$pendingAction) { action in
                guard let action else { return }
                IntentCoordinator.shared.pendingAction = nil
                switch action {
                case .resumeLastPlayed:
                    handleResumeIntent()
                case .playCollection(let id):
                    handlePlayCollectionIntent(collectionId: id)
                }
            }
            .onAppear {
                audioPlayer.bindLibrary(libraryStore)
                bubbleWindowManager.show(audioPlayer: audioPlayer, tabSelection: tabSelection, themeManager: themeManager)
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
            AppLog.debug("Unsupported file type: \(url.pathExtension)")
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
                
                AppLog.debug("Prepared EPUB for preview: \(url.lastPathComponent)")
            } catch {
                AppLog.debug("Failed to prepare EPUB: \(error)")
            }
        }
    }

    // MARK: - Siri / App Intents Notifications

    private func handleResumeIntent() {
        Task {
            await waitForLibraryReady()
            guard let recent = libraryStore.mostRecentPlayback() else { return }
            await playFromIntent(collection: recent.collection, track: recent.track)
        }
    }

    private func handlePlayCollectionIntent(collectionId: UUID) {
        Task {
            await waitForLibraryReady()
            await libraryStore.ensureCollectionLoaded(collectionId)
            guard let collection = libraryStore.collections.first(where: { $0.id == collectionId }) else { return }
            guard let track = collection.resumeTrack() else { return }
            await playFromIntent(collection: collection, track: track)
        }
    }

    /// Wait for LibraryStore to finish initial load (cold start via Siri).
    private func waitForLibraryReady() async {
        // If collections are already loaded, proceed immediately
        if !libraryStore.collections.isEmpty { return }
        // Otherwise wait up to 10 seconds for loading to complete
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if !libraryStore.collections.isEmpty { return }
        }
    }

    @MainActor
    private func playFromIntent(collection: AudiobookCollection, track: AudiobookTrack) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = baiduAuth.token else {
                tabSelection.selectedTab = .personal
                baiduAuth.signIn()
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }

        tabSelection.selectedTab = .playing
    }
}

private struct PendingEbookImport: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}


// MARK: - App Delegate for Quick Actions

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var pendingShortcutItem: UIApplicationShortcutItem?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iCloud storage diagnostics
        AppLog.debug("[iCloud] isAvailable: \(iCloudStorage.isAvailable)")
        AppLog.debug("[iCloud] rootURL: \(iCloudStorage.rootURL.path)")

        // If launched from a home-screen quick action, capture it and defer handling
        // until the SwiftUI hierarchy is up. Returning false prevents the system
        // from calling performActionFor automatically during cold start.
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            pendingShortcutItem = shortcutItem
            return false
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let shortcutItem = pendingShortcutItem else { return }
        pendingShortcutItem = nil
        _ = handle(shortcutItem: shortcutItem)
    }

    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let handled = handle(shortcutItem: shortcutItem)
        completionHandler(handled)
    }

    @discardableResult
    private func handle(shortcutItem: UIApplicationShortcutItem) -> Bool {
        if shortcutItem.type == "com.senaca.AudiobookPlayer.continueLast" {
            // Ensure delivery happens after SwiftUI views have subscribed.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .resumePlaybackShortcut, object: nil)
            }
            return true
        }
        return false
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
