import SwiftUI

struct EbookReaderView: View {
    let track: AudiobookTrack
    let collection: AudiobookCollection
    
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @State private var textContent: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 50)
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text(textContent)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(8)
                        .padding()
                }
            }
        }
        .navigationTitle(track.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    audioPlayer.play(track: track, in: collection, token: nil)
                } label: {
                    Label("Play", systemImage: "play.circle.fill")
                }
            }
        }
        .task {
            await loadContent()
        }
    }
    
    private func loadContent() async {
        isLoading = true
        defer { isLoading = false }
        
        switch track.location {
        case .text(let content):
            textContent = content
        case .cachedText(let filename):
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            do {
                textContent = try String(contentsOf: url)
            } catch {
                errorMessage = "Failed to load text content: \(error.localizedDescription)"
            }
        default:
            errorMessage = "This track does not contain text content."
        }
    }
}
