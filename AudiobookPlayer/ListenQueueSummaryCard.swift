import SwiftUI

/// Compact "Up Next" card shown on the Playing tab above the listening history.
/// - Shows the first few pending queue items (tap to play a specific one).
/// - A "Manage" link pushes `ListenQueueView`.
/// - A small "Play from Queue" toggle flips `ListenQueueStore.playFromQueueEnabled`
///   so auto-advance uses the queue when a track ends.
///
/// The card is entirely hidden when the pending queue is empty — the caller
/// renders `ListenQueueSummaryCard()` unconditionally and we decide here whether
/// to draw anything.
struct ListenQueueSummaryCard: View {
    @EnvironmentObject private var listenQueueStore: ListenQueueStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager

    /// How many rows to preview inline before "show more".
    private let previewLimit = 3

    @State private var missingAuthAlert = false

    var body: some View {
        if listenQueueStore.resolvedPending.isEmpty {
            EmptyView()
        } else {
            cardBody
                .alert(
                    NSLocalizedString("connect_baidu_first", comment: "Alert title"),
                    isPresented: $missingAuthAlert
                ) {
                    Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
                } message: {
                    Text(NSLocalizedString("connect_baidu_before_stream", comment: "Alert message"))
                }
        }
    }

    private var cardBody: some View {
        let items = Array(listenQueueStore.resolvedPending.prefix(previewLimit))
        let totalCount = listenQueueStore.resolvedPending.count

        return VStack(alignment: .leading, spacing: 12) {
            header(totalCount: totalCount)

            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                    itemRow(index: pair.offset + 1, resolved: pair.element)
                }
            }

            if totalCount > items.count {
                Text(String(
                    format: NSLocalizedString(
                        "queue_more_items",
                        value: "+%d more",
                        comment: "Extra queue items beyond the preview"
                    ),
                    totalCount - items.count
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: $listenQueueStore.playFromQueueEnabled) {
                Label {
                    Text(NSLocalizedString(
                        "queue_play_from_queue",
                        value: "Play from Queue",
                        comment: "Toggle auto-advance from queue"
                    ))
                    .font(.subheadline)
                } icon: {
                    Image(systemName: "play.square.stack")
                }
            }
            .toggleStyle(.switch)
            .tint(.indigo)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func header(totalCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.indigo)
            Text(String(
                format: NSLocalizedString(
                    "queue_up_next_count",
                    value: "Up Next · %d items",
                    comment: "Up next header with count"
                ),
                totalCount
            ))
            .font(.headline)

            Spacer()

            NavigationLink {
                ListenQueueView()
            } label: {
                Text(NSLocalizedString("queue_manage", value: "Manage", comment: "Manage queue link"))
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func itemRow(index: Int, resolved: ListenQueueStore.ResolvedItem) -> some View {
        Button {
            play(resolved)
        } label: {
            HStack(spacing: 10) {
                Text("\(index).")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(resolved.displayTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundStyle(resolved.isMissing ? Color.secondary : .primary)
                        if case .collection = resolved.item.target {
                            Image(systemName: "square.stack.3d.up")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let subtitle = resolved.displaySubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolved.isMissing)
    }

    private func play(_ resolved: ListenQueueStore.ResolvedItem) {
        guard !resolved.isMissing, let collection = resolved.collection else { return }

        let track: AudiobookTrack?
        if let direct = resolved.track {
            track = direct
        } else {
            track = listenQueueStore.firstUnfinishedTrack(in: collection)
                ?? collection.resumeTrack()
                ?? collection.tracks.first
        }
        guard let track else { return }

        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                missingAuthAlert = true
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }
    }
}
