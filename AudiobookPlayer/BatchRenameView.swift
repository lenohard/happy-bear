import SwiftUI

struct BatchRenameView: View {
    let tracks: [AudiobookTrack]
    let onApply: ([UUID: String]) -> Void
    let onCancel: () -> Void

    @State private var selectedMode: RenameMode = .delete
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var previewChanges: [UUID: String] = [:]

    enum RenameMode: String, CaseIterable, Identifiable {
        case delete = "Delete Text"
        case replace = "Replace Text"
        
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mode Selection
                Picker("Mode", selection: $selectedMode) {
                    ForEach(RenameMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Input Fields
                VStack(spacing: 16) {
                    TextField("Text to find...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if selectedMode == .replace {
                        TextField("Replace with...", text: $replacementText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)

                // Preview List
                List {
                    Section {
                        if previewChanges.isEmpty {
                            Text(searchText.isEmpty ? "Enter text to see preview" : "No matches found")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(tracks.filter { previewChanges.keys.contains($0.id) }) { track in
                                if let newTitle = previewChanges[track.id] {
                                    VStack(alignment: .leading) {
                                        Text(track.displayName)
                                            .strikethrough()
                                            .foregroundStyle(.secondary)
                                        Text(newTitle)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.blue)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } header: {
                        Text("Preview Changes (\(previewChanges.count))")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Batch Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(previewChanges)
                    }
                    .disabled(previewChanges.isEmpty)
                }
            }
            .onChange(of: searchText) { _ in updatePreview() }
            .onChange(of: replacementText) { _ in updatePreview() }
            .onChange(of: selectedMode) { _ in updatePreview() }
        }
    }

    private func updatePreview() {
        guard !searchText.isEmpty else {
            previewChanges = [:]
            return
        }

        var changes: [UUID: String] = [:]

        for track in tracks {
            let original = track.displayName
            var newTitle = original

            if selectedMode == .delete {
                newTitle = original.replacingOccurrences(of: searchText, with: "")
            } else {
                newTitle = original.replacingOccurrences(of: searchText, with: replacementText)
            }

            // Only add if there's a change and the result isn't empty
            if newTitle != original && !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                changes[track.id] = newTitle
            }
        }

        previewChanges = changes
    }
}

#Preview {
    BatchRenameView(
        tracks: [
            AudiobookTrack(id: UUID(), displayName: "Chapter 01 - Intro", filename: "01.mp3", location: .local(urlBookmark: Data()), fileSize: 0, duration: 0, trackNumber: 1, checksum: nil, metadata: [:]),
            AudiobookTrack(id: UUID(), displayName: "Chapter 02 - Story", filename: "02.mp3", location: .local(urlBookmark: Data()), fileSize: 0, duration: 0, trackNumber: 2, checksum: nil, metadata: [:])
        ],
        onApply: { _ in },
        onCancel: {}
    )
}
