import SwiftUI

struct TrackPickerView: View {
    let collectionID: UUID
    let onTracksSelected: ([AudiobookTrack]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var selectedEntries: OrderedSet<BaiduNetdiskEntry> = []
    @State private var browsePath: String = "/"
    @State private var isPresentingBrowser = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selectedEntries.isEmpty {
                    emptyState
                } else {
                    selectedList
                }

                footerControls
            }
            .navigationTitle(NSLocalizedString("add_tracks_button", comment: "Track picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingBrowser = true
                    } label: {
                        Label(NSLocalizedString("track_picker_browse_button", comment: "Browse Netdisk"), systemImage: "folder.badge.plus")
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", comment: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .alert(item: Binding(
                get: {
                    errorMessage.map { IdentifiedError(message: $0) }
                },
                set: { newValue in
                    errorMessage = newValue?.message
                }
            )) { error in
                Alert(
                    title: Text(NSLocalizedString("error_title", comment: "Error title")),
                    message: Text(error.message),
                    dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK button")))
                )
            }
            .sheet(isPresented: $isPresentingBrowser) {
                NavigationStack {
                    BaiduNetdiskBrowserView(
                        tokenProvider: { authViewModel.token },
                        onSelectFile: toggleSelection,
                        onSelectFolder: { path in
                            browsePath = path
                        }
                    )
                }
            }
        }
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: validateState)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.full")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)

            Text(NSLocalizedString("track_picker_placeholder_title", comment: "Placeholder title"))
                .font(.headline)

            Text(NSLocalizedString("track_picker_placeholder_message", comment: "Placeholder message"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Button {
                isPresentingBrowser = true
            } label: {
                Label(NSLocalizedString("track_picker_browse_button", comment: "Browse Netdisk"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 32)
    }

    private var selectedList: some View {
        List {
            ForEach(Array(selectedEntries.enumerated()), id: \.element.fsId) { index, entry in
                HStack(spacing: 12) {
                    Text(String(format: "%02d", index + 1))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.serverFilename)
                            .font(.body)
                            .lineLimit(2)

                        Text(formatBytes(entry.size))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(entry.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        toggleSelection(entry)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(entry)
                }
            }
            .onMove(perform: reorder)
        }
        .listStyle(.plain)
    }

    private var footerControls: some View {
        VStack(spacing: 12) {
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("track_picker_selection_summary", comment: "Selection summary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(format: NSLocalizedString("track_picker_selected_count", comment: "Selected count"), selectedEntries.count))
                        .font(.headline)
                }

                Spacer()

                Button(NSLocalizedString("track_picker_add_selected", comment: "Add selected")) {
                    addSelectedTracks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func validateState() {
        guard library.canModifyCollection(collectionID) else {
            errorMessage = NSLocalizedString("track_picker_collection_readonly", comment: "Collection read-only message")
            return
        }

        guard authViewModel.token != nil else {
            errorMessage = NSLocalizedString("connect_baidu_first", comment: "Connect Baidu first")
            return
        }
    }

    private func toggleSelection(_ entry: BaiduNetdiskEntry) {
        guard !entry.isDir else { return }

        if let index = selectedEntries.firstIndex(of: entry) {
            selectedEntries.remove(at: index)
        } else {
            selectedEntries.append(entry)
        }
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        selectedEntries.move(fromOffsets: offsets, toOffset: destination)
    }

    private func addSelectedTracks() {
        let baseIndex = library.collections.first { $0.id == collectionID }?.tracks.count ?? 0

        let newTracks: [AudiobookTrack] = selectedEntries.enumerated().map { offset, entry in
            AudiobookTrack(
                id: UUID(),
                displayName: entry.serverFilename,
                filename: entry.serverFilename,
                location: .baidu(fsId: entry.fsId, path: entry.path),
                fileSize: entry.size,
                duration: nil,
                trackNumber: baseIndex + offset + 1,
                checksum: entry.md5,
                metadata: [:]
            )
        }

        guard !newTracks.isEmpty else { return }

        onTracksSelected(newTracks)
        dismiss()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct IdentifiedError: Identifiable {
    let id = UUID()
    let message: String
}

// Minimal ordered set for preserving selection order without duplicates
private struct OrderedSet<Element: Equatable>: RandomAccessCollection, MutableCollection, RangeReplaceableCollection {
    private var storage: [Element] = []

    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }

    init() {}
    init(_ elements: [Element]) {
        storage = elements.reduce(into: []) { result, element in
            if !result.contains(element) {
                result.append(element)
            }
        }
    }

    subscript(position: Int) -> Element {
        get { storage[position] }
        set { storage[position] = newValue }
    }

    mutating func append(_ element: Element) {
        guard !storage.contains(element) else { return }
        storage.append(element)
    }

    mutating func remove(at index: Int) {
        storage.remove(at: index)
    }

    mutating func removeAll() {
        storage.removeAll()
    }

    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        storage.move(fromOffsets: offsets, toOffset: destination)
    }

    func firstIndex(of element: Element) -> Int? {
        storage.firstIndex(of: element)
    }

    var count: Int { storage.count }

    func enumerated() -> EnumeratedSequence<[Element]> {
        storage.enumerated()
    }
}

#Preview {
    TrackPickerView(collectionID: UUID(), onTracksSelected: { _ in })
        .environmentObject(LibraryStore(autoLoadOnInit: false))
        .environmentObject(BaiduAuthViewModel())
}
