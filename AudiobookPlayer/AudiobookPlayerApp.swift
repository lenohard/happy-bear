import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @StateObject private var audioPlayer = AudioPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
        }
    }
}
