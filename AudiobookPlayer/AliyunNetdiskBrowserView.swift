import SwiftUI

struct AliyunNetdiskBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AliyunNetdiskBrowserViewModel
    @State private var searchText = "" // Search not fully implemented in VM yet, but keeping UI consistent
    @State private var isSearching = false

    var onSelectFile: ((AliyunNetdiskEntry) -> Void)?
    var onSelectFolder: ((String) -> Void)? // Note: "String" here will be file_id for Aliyun
    var selectedEntryIDs: Set<String> // Aliyun uses String IDs
    var onToggleSelection: ((AliyunNetdiskEntry) -> Void)?

    init(
        tokenProvider: @escaping () -> AliyunOAuthToken?,
        onSelectFile: ((AliyunNetdiskEntry) -> Void)? = nil,
        onSelectFolder: ((String) -> Void)? = nil,
        selectedEntryIDs: Set<String> = [],
        onToggleSelection: ((AliyunNetdiskEntry) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: AliyunNetdiskBrowserViewModel(tokenProvider: tokenProvider))
        self.onSelectFile = onSelectFile
        self.onSelectFolder = onSelectFolder
        self.selectedEntryIDs = selectedEntryIDs
        self.onToggleSelection = onToggleSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !viewModel.currentPath.isEmpty {
                    Text("Directory ID: " + viewModel.currentPath) // Aliyun paths are IDs, so display might need refinement later
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
        .navigationTitle("Aliyun Drive")
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
                            let count = playableEntryCount
                            if count > 0 {
                                Text("Use This Folder (\(count) files here)")
                            } else {
                                Text("Use This Folder")
                            }
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        // Search disabled for now until implemented in VM/API
        /*
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search files"
        )
        */
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
            Label("This folder is empty.", systemImage: "tray")
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
                            Image(systemName: selectedEntryIDs.contains(entry.fileId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedEntryIDs.contains(entry.fileId) ? Color.accentColor : Color.secondary)
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

                                Text(entry.name)
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
                                    Text(entry.name)
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

    private var filteredEntries: [AliyunNetdiskEntry] {
        viewModel.entries
    }

    private var playableEntryCount: Int {
        viewModel.entries.reduce(into: 0) { partialResult, entry in
            guard !entry.isDir else { return }
            let ext = entry.fileExtension?.lowercased() ?? ""
            if PlayableMediaFormat.isPlayableExtension(ext) {
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
                    dismiss()
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

    private func detailText(for entry: AliyunNetdiskEntry) -> String? {
        if entry.isDir {
            return nil
        }

        var segments: [String] = []
        
        if let size = entry.size {
            let sizeFormatter = ByteCountFormatter()
            sizeFormatter.countStyle = .file
            segments.append(sizeFormatter.string(fromByteCount: size))
        }

        // Parse date if needed, currently string in struct
        // Keeping it simple for now
        
        return segments.joined(separator: " • ")
    }
}
