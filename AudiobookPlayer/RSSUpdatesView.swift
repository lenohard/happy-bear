import SwiftUI

struct RSSUpdatesView: View {
    let updates: [UUID: [AudiobookTrack]]
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTracks: Set<UUID> = []
    @State private var expandedCollections: Set<UUID> = []
    @State private var sortedCollectionIds: [UUID] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(sortedCollectionIds, id: \.self) { collectionId in
                    if let collection = library.collections.first(where: { $0.id == collectionId }),
                       let tracks = updates[collectionId] {

                        Section {
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedCollections.contains(collectionId) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedCollections.insert(collectionId)
                                        } else {
                                            expandedCollections.remove(collectionId)
                                        }
                                    }
                                )
                            ) {
                                ForEach(tracks) { track in
                                    MultipleSelectionRow(title: track.displayName, isSelected: selectedTracks.contains(track.id)) {
                                        if selectedTracks.contains(track.id) {
                                            selectedTracks.remove(track.id)
                                        } else {
                                            selectedTracks.insert(track.id)
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(collection.title)
                                        .font(.headline)
                                    Spacer()
                                    Button(action: {
                                        toggleSelection(for: tracks)
                                    }) {
                                        Text(areAllSelected(tracks) ? "Unselect All" : "Select All")
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("rss_updates_title", value: "RSS Updates", comment: "RSS updates view title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel_button", value: "Cancel", comment: "Cancel button")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("import_button", value: "Import", comment: "Import button")) {
                        importSelectedTracks()
                    }
                    .disabled(selectedTracks.isEmpty)
                }
            }
            .onAppear {
                // Pre-calculate sorted collection IDs
                sortedCollectionIds = updates.keys.sorted { id1, id2 in
                    let c1 = library.collections.first(where: { $0.id == id1 })
                    let c2 = library.collections.first(where: { $0.id == id2 })
                    return (c1?.title ?? "") < (c2?.title ?? "")
                }

                // Select all by default
                var allIds: Set<UUID> = []
                for tracks in updates.values {
                    for track in tracks {
                        allIds.insert(track.id)
                    }
                }
                selectedTracks = allIds
                // Expand all by default
                expandedCollections = Set(updates.keys)
            }
        }
    }

    private func areAllSelected(_ tracks: [AudiobookTrack]) -> Bool {
        tracks.allSatisfy { selectedTracks.contains($0.id) }
    }

    private func toggleSelection(for tracks: [AudiobookTrack]) {
        if areAllSelected(tracks) {
            for track in tracks {
                selectedTracks.remove(track.id)
            }
        } else {
            for track in tracks {
                selectedTracks.insert(track.id)
            }
        }
    }

    private func importSelectedTracks() {
        for (collectionId, tracks) in updates {
            let tracksToImport = tracks.filter { selectedTracks.contains($0.id) }
            if !tracksToImport.isEmpty {
                library.addTracks(to: collectionId, tracks: tracksToImport)
            }
        }
        dismiss()
    }
}

struct MultipleSelectionRow: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
