import SwiftUI

/// Full-screen listen queue management view.
/// - Segmented control: Pending / Completed
/// - Pending: ordered list, drag-to-reorder, leading swipe "Mark Done", trailing swipe "Remove"
/// - Completed: most recent first, swipe "Undo" or "Delete"
/// - Toolbar: close button, "Play from queue" toggle, "Clear completed" (in completed tab)
struct ListenQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var listenQueueStore: ListenQueueStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var section: Section = .pending
    @State private var showClearConfirm = false
    @State private var missingAuthAlert = false

    private enum Section: String, CaseIterable, Identifiable {
        case pending
        case completed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pending:
                return NSLocalizedString("queue_section_pending", value: "Up Next", comment: "Queue pending section title")
            case .completed:
                return NSLocalizedString("queue_section_completed", value: "Done", comment: "Queue completed section title")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                switch section {
                case .pending:
                    pendingSection
                case .completed:
                    completedSection
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
            .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemBackground))
        }
        .navigationTitle(Text(NSLocalizedString("queue_title", value: "Listen Queue", comment: "Listen queue view title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Toggle(isOn: $listenQueueStore.playFromQueueEnabled) {
                    Label(
                        NSLocalizedString("queue_play_from_queue", value: "Play from Queue", comment: "Toggle auto-advance from queue"),
                        systemImage: "play.square.stack"
                    )
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if section == .completed && !listenQueueStore.resolvedCompleted.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(
                            NSLocalizedString("queue_clear_completed", value: "Clear Completed", comment: "Clear completed queue items"),
                            systemImage: "trash"
                        )
                    }
                }
                Button {
                    dismiss()
                } label: {
                    Text(NSLocalizedString("close_button", comment: "Close button"))
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("queue_clear_completed_confirm", value: "Clear all completed items?", comment: "Confirm clear completed"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(
                NSLocalizedString("queue_clear_completed", value: "Clear Completed", comment: "Clear completed queue items"),
                role: .destructive
            ) {
                Task { await listenQueueStore.clearCompleted() }
            }
            Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
        }
        .alert(NSLocalizedString("connect_baidu_first", comment: "Alert title"), isPresented: $missingAuthAlert) {
            Button(NSLocalizedString("ok_button", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("connect_baidu_before_stream", comment: "Alert message to sign in before streaming"))
        }
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingSection: some View {
        if listenQueueStore.resolvedPending.isEmpty {
            emptyState(
                systemImage: "list.bullet.rectangle",
                title: NSLocalizedString("queue_empty_pending_title", value: "Your queue is empty", comment: "Empty pending queue title"),
                message: NSLocalizedString("queue_empty_pending_message", value: "Swipe on a track or collection to add it here.", comment: "Empty pending queue message")
            )
        } else {
            ForEach(listenQueueStore.resolvedPending) { resolved in
                ListenQueueRow(
                    resolved: resolved,
                    isActive: isActive(resolved),
                    onTap: { play(resolved) }
                )
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await listenQueueStore.markDone(itemID: resolved.id) }
                    } label: {
                        Label(
                            NSLocalizedString("queue_mark_done", value: "Mark Done", comment: "Mark queue item as done"),
                            systemImage: "checkmark.circle"
                        )
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await listenQueueStore.remove(itemID: resolved.id) }
                    } label: {
                        Label(
                            NSLocalizedString("queue_remove", value: "Remove", comment: "Remove queue item"),
                            systemImage: "trash"
                        )
                    }
                }
            }
            .onMove(perform: movePending)
        }
    }

    // MARK: - Completed

    @ViewBuilder
    private var completedSection: some View {
        if listenQueueStore.resolvedCompleted.isEmpty {
            emptyState(
                systemImage: "checkmark.seal",
                title: NSLocalizedString("queue_empty_completed_title", value: "Nothing finished yet", comment: "Empty completed queue title"),
                message: NSLocalizedString("queue_empty_completed_message", value: "Items you complete from the queue will show up here.", comment: "Empty completed queue message")
            )
        } else {
            ForEach(listenQueueStore.resolvedCompleted) { resolved in
                ListenQueueRow(
                    resolved: resolved,
                    isActive: isActive(resolved),
                    onTap: { play(resolved) }
                )
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await listenQueueStore.unmarkDone(itemID: resolved.id) }
                    } label: {
                        Label(
                            NSLocalizedString("queue_undo", value: "Move Back", comment: "Move completed item back to pending"),
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await listenQueueStore.remove(itemID: resolved.id) }
                    } label: {
                        Label(
                            NSLocalizedString("queue_remove", value: "Remove", comment: "Remove queue item"),
                            systemImage: "trash"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func movePending(from source: IndexSet, to destination: Int) {
        guard let fromIndex = source.first else { return }
        let items = listenQueueStore.resolvedPending
        guard fromIndex < items.count else { return }
        let moved = items[fromIndex]
        // SwiftUI gives a destination in the *current* ordering that is one past
        // the intended slot when moving downward. `move(itemID:to:)` in the store
        // expects a 0-based target index within the pending list.
        var target = destination
        if destination > fromIndex { target -= 1 }
        target = max(0, min(target, items.count - 1))
        Task { await listenQueueStore.move(itemID: moved.id, to: target) }
    }

    private func isActive(_ resolved: ListenQueueStore.ResolvedItem) -> Bool {
        guard let track = resolved.track else { return false }
        return audioPlayer.currentTrack?.id == track.id
    }

    private func play(_ resolved: ListenQueueStore.ResolvedItem) {
        guard !resolved.isMissing, let collection = resolved.collection else { return }
        let track: AudiobookTrack?
        if let direct = resolved.track {
            track = direct
        } else {
            // Collection target → play first unfinished track.
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
        tabSelection.switchToPlayingTab()
        dismiss()
    }
}

// MARK: - Row

struct ListenQueueRow: View {
    let resolved: ListenQueueStore.ResolvedItem
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            coverView

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(resolved.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if isActive {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    if case .collection = resolved.item.target {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(NSLocalizedString("queue_collection_badge", value: "Whole collection", comment: "Collection badge in queue row")))
                    }
                }

                if let subtitle = resolved.displaySubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                progressLine
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(resolved.isMissing ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var coverView: some View {
        if let collection = resolved.collection {
            CollectionCoverArtView(
                cover: collection.coverAsset,
                title: collection.title,
                size: 44,
                cornerRadius: 6
            )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "questionmark")
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if resolved.isMissing {
            Text(NSLocalizedString("queue_missing_note", value: "No longer available", comment: "Item missing note"))
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let progress = resolved.progress {
            HStack(spacing: 6) {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let remaining = resolved.remainingTracks {
            Text(String(
                format: NSLocalizedString("queue_remaining_tracks", value: "%d tracks left", comment: "Remaining tracks in collection queue row"),
                remaining
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
