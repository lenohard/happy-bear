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
            .navigationTitle(themeManager.colors.isFestive ? "⛄ 个人" : "个人")
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
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}

private struct PersonalCardRow: View {
    static let horizontalPadding: CGFloat = 20
    static let iconContainerSize: CGFloat = 42
    static let contentSpacing: CGFloat = 12

    let icon: String
    let title: String

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themeManager.colors.isFestive ? Color(uiColor: .systemGray5) : Color.accentColor.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.festiveRed : Color.accentColor)
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
