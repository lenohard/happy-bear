import SwiftUI

struct BaiduNetdiskBrowserView: View {
    @StateObject private var viewModel: BaiduNetdiskBrowserViewModel
    @State private var searchText = ""
    @State private var isSearching = false

    var onSelectFile: ((BaiduNetdiskEntry) -> Void)?
    var onSelectFolder: ((String) -> Void)?
    var selectedEntryIDs: Set<Int64>
    var onToggleSelection: ((BaiduNetdiskEntry) -> Void)?

    private let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav"]

    init(
        tokenProvider: @escaping () -> BaiduOAuthToken?,
        onSelectFile: ((BaiduNetdiskEntry) -> Void)? = nil,
        onSelectFolder: ((String) -> Void)? = nil,
        selectedEntryIDs: Set<Int64> = [],
        onToggleSelection: ((BaiduNetdiskEntry) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BaiduNetdiskBrowserViewModel(tokenProvider: tokenProvider))
        self.onSelectFile = onSelectFile
        self.onSelectFolder = onSelectFolder
        self.selectedEntryIDs = selectedEntryIDs
        self.onToggleSelection = onToggleSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !viewModel.currentPath.isEmpty {
                    Text(viewModel.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                contentList
            }

            // Sticky footer for multi-select mode
            if onToggleSelection != nil && !selectedEntryIDs.isEmpty {
                stickyFooter
            }
        }
        .navigationTitle("Baidu Netdisk")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if viewModel.canNavigateUp {
                    Button {
                        viewModel.goUp()
                    } label: {
                        Label("Up One Level", systemImage: "arrow.uturn.up")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }

            if let onSelectFolder {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onSelectFolder(viewModel.currentPath)
                    } label: {
                        Label {
                            let count = audioEntryCount
                            if count > 0 {
                                Text("Use This Folder (\(count))")
                            } else {
                                Text("Use This Folder")
                            }
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                    .disabled(audioEntryCount == 0 || viewModel.isLoading)
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search files"
        )
        .onSubmit(of: .search) {
            if !searchTextTrimmed.isEmpty {
                isSearching = true
                viewModel.search(keyword: searchTextTrimmed)
            }
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty {
                isSearching = false
                viewModel.refresh()
            }
        }
        .onAppear {
            if viewModel.entries.isEmpty && !viewModel.isLoading {
                viewModel.refresh()
            }
        }
        .onAppear {
            if viewModel.entries.isEmpty && !viewModel.isLoading {
                viewModel.refresh()
            }
        }
        .refreshable {
            viewModel.refresh()
        }
    }

#Preview("Baidu Netdisk Browser") {
    NavigationStack {
        BaiduNetdiskBrowserView(tokenProvider: { nil })
            .navigationBarTitleDisplayMode(.inline)
    }
}

    @ViewBuilder
    private var contentList: some View {
        if viewModel.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let error = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Unable to load directory", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if filteredEntries.isEmpty {
            Label(searchTextTrimmed.isEmpty ? "This folder is empty." : "No results for \"\(searchTextTrimmed)\"",
                  systemImage: searchTextTrimmed.isEmpty ? "tray" : "magnifyingglass")
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
        } else {
            ForEach(filteredEntries) { entry in
                HStack {
                    if let onToggleSelection = onToggleSelection {
                        // Multi-select mode: show checkbox
                        Button {
                            onToggleSelection(entry)
                        } label: {
                            Image(systemName: selectedEntryIDs.contains(entry.fsId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedEntryIDs.contains(entry.fsId) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                    }

                    if entry.isDir {
                        // Folder: navigable
                        Button {
                            searchText = ""
                            viewModel.enter(entry)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)

                                Text(entry.serverFilename)
                                    .font(.body)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.primary)
                    } else {
                        // File: selectable
                        Button {
                            if let onToggleSelection {
                                onToggleSelection(entry)
                            } else {
                                onSelectFile?(entry)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "doc.waveform")
                                    .foregroundStyle(Color.blue)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.serverFilename)
                                        .font(.body)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let detail = detailText(for: entry) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.primary)
                    }
                }
            }
        }
    }

    private var searchTextTrimmed: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [BaiduNetdiskEntry] {
        // During search, entries are already filtered by the API
        // Otherwise, we're showing the directory contents
        viewModel.entries
    }

    private var audioEntryCount: Int {
        viewModel.entries.reduce(into: 0) { partialResult, entry in
            guard !entry.isDir else { return }
            let ext = entry.serverFilename.split(separator: ".").last?.lowercased() ?? ""
            if audioExtensions.contains(ext) {
                partialResult += 1
            }
        }
    }

    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Text("\(selectedEntryIDs.count) items selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    // Dismiss sheet - parent view (TrackPickerView) will handle the selections
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        rootViewController.dismiss(animated: true)
                    }
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func detailText(for entry: BaiduNetdiskEntry) -> String? {
        if entry.isDir {
            return nil
        }

        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file
        let sizeString = sizeFormatter.string(fromByteCount: entry.size)

        let date = Date(timeIntervalSince1970: entry.serverMtime)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return "\(sizeString) • \(formatter.string(from: date))"
    }
}
