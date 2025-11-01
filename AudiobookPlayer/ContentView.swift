import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @StateObject private var authViewModel = BaiduAuthViewModel()
    @State private var hasLoadedSample = false

    private let sampleURL = URL(string: "https://cdn.simplecast.com/audio/2cf6dcce-238f-4df5-b285-dc59b9c8db05/episodes/1e4f2b88-9e7e-4c43-8687-0a7cba1cc403/audio/9c1b7d1a-b4f6-44ef-9b59-4cdc61814fdb/default.mp3")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    baiduAuthSection
                    sampleSection
                }
                .padding()
            }
            .navigationTitle("Audiobook Player")
        }
        .onDisappear { audioPlayer.reset() }
    }

    @ViewBuilder
    private var playbackControls: some View {
        VStack(spacing: 16) {
            if hasLoadedSample {
                timelineSlider

                HStack {
                    Text(audioPlayer.currentTime.formattedTimestamp)
                    Spacer()
                    Text(audioPlayer.duration.formattedTimestamp)
                }
                .font(.caption.monospacedDigit())

                Button {
                    audioPlayer.togglePlayback()
                } label: {
                    Label(audioPlayer.isPlaying ? "Pause" : "Play", systemImage: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    audioPlayer.prepare(with: sampleURL)
                    hasLoadedSample = true
                } label: {
                    Label("Load Sample Audio", systemImage: "waveform.circle.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var timelineSlider: some View {
        Slider(
            value: Binding(
                get: { audioPlayer.currentTime },
                set: { audioPlayer.seek(to: $0) }
            ),
            in: 0...(max(audioPlayer.duration, 1))
        )
        .tint(.accentColor)
    }

    private var sampleSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Sample Audiobook")
                    .font(.title2)
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Streamed via AVFoundation using a remote MP3 source.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            playbackControls

            if let message = audioPlayer.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var baiduAuthSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Baidu Cloud Sign-In", systemImage: "icloud.and.arrow.down")
                    .font(.headline)

                Text("Connect your Baidu Netdisk account to browse and download audiobooks.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let token = authViewModel.token {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Access token acquired.")
                            .font(.subheadline)
                            .bold()

                        if let scope = token.scope, !scope.isEmpty {
                            Text("Scopes: \(scope)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("Expires \(token.formattedExpiry)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        authViewModel.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        authViewModel.signIn()
                    } label: {
                        Label("Sign in with Baidu", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authViewModel.isAuthorizing)

                    if authViewModel.isAuthorizing {
                        ProgressView("Authorizing…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let error = authViewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension Double {
    var formattedTimestamp: String {
        guard isFinite else { return "--:--" }

        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioPlayerViewModel())
}
