import SwiftUI

struct BaiduNetdiskBrowserView: View {
    @StateObject private var viewModel: BaiduNetdiskBrowserViewModel
    @State private var searchText = ""
    var onSelectFile: (BaiduNetdiskEntry) -> Void

    init(
        tokenProvider: @escaping () -> BaiduOAuthToken?,
        onSelectFile: @escaping (BaiduNetdiskEntry) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: BaiduNetdiskBrowserViewModel(tokenProvider: tokenProvider))
        self.onSelectFile = onSelectFile
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
        }
        .searchable(text: $searchText, prompt: "Search in folder")
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
                        onSelectFile(entry)
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
        let query = searchTextTrimmed
        guard !query.isEmpty else {
            return viewModel.entries
        }
        return viewModel.entries.filter { entry in
            entry.serverFilename.localizedCaseInsensitiveContains(query)
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
