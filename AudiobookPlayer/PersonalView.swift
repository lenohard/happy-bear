import SwiftUI

struct PersonalView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: showListeningHistorySheet) {
                        Label {
                            Text(NSLocalizedString("listening_history", comment: "Listening history section title"))
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        ListeningStatisticsView()
                    } label: {
                        Label {
                            Text(NSLocalizedString("listening_statistics", comment: "Listening statistics section title"))
                        } icon: {
                            Image(systemName: "chart.bar.fill")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsTabView()
                    } label: {
                        Label(NSLocalizedString("settings_tab", comment: "Settings tab"), systemImage: "gear")
                    }
                }
            }
            .navigationTitle("Personal")
            .sheet(isPresented: $showHistorySheet) {
                ListeningHistorySheet(
                    entries: historySheetEntries,
                    onResume: { collection, track in
                        resumePlayback(collection: collection, track: track)
                        showHistorySheet = false
                    }
                )
            }
        }
    }

    private func showListeningHistorySheet() {
        showHistorySheet = true
    }

    @State private var showHistorySheet = false

    private var historySheetEntries: [ListeningHistoryEntry] {
        buildListeningHistory(from: library, using: audioPlayer)
    }

    private func resumePlayback(collection: AudiobookCollection, track: AudiobookTrack) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                // Handle missing auth if needed, or rely on PlayingView to handle it when switching
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }
        tabSelection.switchToPlayingTab()
    }

}
 
private struct ListeningHistorySheet: View {
    let entries: [ListeningHistoryEntry]
    let onResume: (AudiobookCollection, AudiobookTrack) -> Void

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    onResume(entry.collection, entry.track)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.collection.title)
                                .font(.subheadline)
                                .bold()
                                .lineLimit(2)

                            Text(entry.track.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            if let duration = entry.state.duration, duration > 0 {
                                Text(percentString(position: entry.state.position, duration: duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.state.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(NSLocalizedString("listening_history", comment: "Listening history section title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("close_button", comment: "Close button")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func percentString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let clamped = max(0, min(position / duration, 1))
        let percent = Int(round(clamped * 100))
        return "\(percent)%"
    }

    @Environment(\.dismiss) private var dismiss
}
