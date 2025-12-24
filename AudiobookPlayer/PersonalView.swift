import SwiftUI

struct PersonalView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showHistorySheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                (themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        historyAndStatisticsCard
                        settingsCard
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Personal")
            .toolbarBackground(themeManager.colors.isFestive ? .hidden : .visible, for: .navigationBar)
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
        .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
    }

    private var historyAndStatisticsCard: some View {
        PersonalCard {
            Button(action: showListeningHistorySheet) {
                PersonalCardRow(
                    icon: "clock.arrow.circlepath",
                    title: NSLocalizedString("listening_history", comment: "Listening history section title")
                )
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, PersonalCardRow.dividerLeadingInset)
                .padding(.trailing, PersonalCardRow.horizontalPadding)

            NavigationLink {
                ListeningStatisticsView()
            } label: {
                PersonalCardRow(
                    icon: "chart.bar.fill",
                    title: NSLocalizedString("listening_statistics", comment: "Listening statistics section title")
                )
            }
            .tint(.primary)
        }
    }

    private var settingsCard: some View {
        PersonalCard {
            NavigationLink {
                SettingsTabView()
            } label: {
                PersonalCardRow(
                    icon: "gear",
                    title: NSLocalizedString("settings_tab", comment: "Settings tab")
                )
            }
            .tint(.primary)
        }
    }

    private func showListeningHistorySheet() {
        showHistorySheet = true
    }

    private var historySheetEntries: [ListeningHistoryEntry] {
        buildListeningHistory(from: library, using: audioPlayer)
    }

    private func resumePlayback(collection: AudiobookCollection, track: AudiobookTrack) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
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

private struct PersonalCard<Content: View>: View {
    @EnvironmentObject private var themeManager: ThemeManager
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(
            themeManager.colors.isFestive ?
            themeManager.colors.secondaryBackground.opacity(0.9) :
            Color(.secondarySystemGroupedBackground)
        ))
        .clipShape(shape)
        .overlay(shape.stroke(
            themeManager.colors.isFestive ?
            themeManager.colors.festiveGold.opacity(0.5) :
            Color(.separator).opacity(0.2)
        ))
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}

private struct PersonalCardRow: View {
    static let horizontalPadding: CGFloat = 20
    static let iconContainerSize: CGFloat = 42
    static let contentSpacing: CGFloat = 12

    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: Self.iconContainerSize, height: Self.iconContainerSize)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private extension PersonalCardRow {
    static var dividerLeadingInset: CGFloat {
        horizontalPadding + iconContainerSize + contentSpacing
    }
}
