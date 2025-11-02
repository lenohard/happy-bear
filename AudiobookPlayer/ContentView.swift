import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            SourcesView()
                .tabItem {
                    Label("Sources", systemImage: "externaldrive.badge.icloud")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(LibraryStore())
        .environmentObject(BaiduAuthViewModel())
}
