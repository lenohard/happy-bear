import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var baiduAuth = BaiduAuthViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
                .environmentObject(libraryStore)
                .environmentObject(baiduAuth)
        }
    }
}
