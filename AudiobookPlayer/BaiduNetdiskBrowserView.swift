import SwiftUI

struct BaiduNetdiskBrowserView: View {
    @StateObject private var viewModel: BaiduNetdiskBrowserViewModel
    @State private var searchText = ""
    @State private var isSearching = false

    var onSelectFile: ((BaiduNetdiskEntry) -> Void)?
    var onSelectFolder: ((String) -> Void)?

    private let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav"]

    init(
        tokenProvider: @escaping () -> BaiduOAuthToken?,
        onSelectFile: ((BaiduNetdiskEntry) -> Void)? = nil,
        onSelectFolder: ((String) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BaiduNetdiskBrowserViewModel(tokenProvider: tokenProvider))
        self.onSelectFile = onSelectFile
        self.onSelectFolder = onSelectFolder
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Current Path", systemImage: "folder")
                    Spacer()
                    Text(viewModel.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // Search options section (shown when search field is active)
            if !searchText.isEmpty || isSearching {
                Section("Search Options") {
                    Toggle("Audio Files Only", isOn: $viewModel.audioOnly)
                        .onChange(of: viewModel.audioOnly) { _ in
                            if !searchTextTrimmed.isEmpty {
                                viewModel.search(keyword: searchTextTrimmed)
                            }
                        }
                }
            }

            Section {
                contentList
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
        .refreshable {
            viewModel.refresh()
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
                Button {
                    if entry.isDir {
                        searchText = ""  // Clear search when entering a folder
                        viewModel.enter(entry)
                    } else {
                        onSelectFile?(entry)
                    }
                } label: {
                    HStack {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc.waveform")
                            .foregroundStyle(entry.isDir ? Color.accentColor : Color.blue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.serverFilename)
                                .font(.body)
                                .lineLimit(2)
                            Text(detailText(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if entry.isDir {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
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

    private func detailText(for entry: BaiduNetdiskEntry) -> String {
        if entry.isDir {
            return "Folder"
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
