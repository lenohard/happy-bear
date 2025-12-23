import SwiftUI

struct ArchivedCollectionsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    
    private var archivedCollections: [AudiobookCollection] {
        library.collections.filter { $0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    
    var body: some View {
        List {
            if archivedCollections.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("no_archived_collections", value: "No Archived Collections", comment: "Empty state title for archived collections"),
                    systemImage: "archivebox",
                    description: Text(NSLocalizedString("archived_collections_hint", value: "Swipe left on a collection in your library to archive it.", comment: "Empty state hint for archived collections"))
                )
            } else {
                ForEach(archivedCollections) { collection in
                    HStack(spacing: 12) {
                        LibraryCollectionRow(collection: collection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Navigate to detail
                                tabSelection.libraryNavigationTarget = collection.id
                            }
                        
                        Button {
                            resumeCollectionPlayback(collection)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 56, alignment: .trailing)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            withAnimation {
                                library.unarchiveCollection(collection)
                            }
                        } label: {
                            Label(NSLocalizedString("unarchive_button", value: "Unarchive", comment: "Unarchive button"), systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                        .labelStyle(.iconOnly)
                        
                        Button(role: .destructive) {
                            library.delete(collection)
                        } label: {
                            Label(NSLocalizedString("delete_button", comment: "Delete button"), systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("archived_collections_title", value: "Archived", comment: "Archived collections view title"))
        .navigationDestination(isPresented: Binding(
            get: { tabSelection.libraryNavigationTarget != nil && library.collections.first(where: { $0.id == tabSelection.libraryNavigationTarget })?.isArchived == true },
            set: { if !$0 { tabSelection.libraryNavigationTarget = nil } }
        )) {
            if let collectionID = tabSelection.libraryNavigationTarget {
                CollectionDetailView(collectionID: collectionID)
            }
        }
    }
    
    private func resumeCollectionPlayback(_ collection: AudiobookCollection) {
        Task {
            await library.ensureCollectionLoaded(collection.id)
            
            await MainActor.run {
                guard let updatedCollection = library.collections.first(where: { $0.id == collection.id }) else { return }
                guard !updatedCollection.tracks.isEmpty else { return }

                if updatedCollection.isMusic {
                    var collectionToPlay = updatedCollection
                    if !collectionToPlay.shuffleEnabled {
                        library.updateShuffle(true, for: collectionToPlay.id)
                        collectionToPlay.shuffleEnabled = true
                    }
                    
                    guard let randomTrack = collectionToPlay.tracks.randomElement() else { return }
                    playTrack(randomTrack, in: collectionToPlay)
                } else {
                    guard let track = updatedCollection.resumeTrack() else { return }
                    playTrack(track, in: updatedCollection)
                }
            }
        }
    }
    
    private func playTrack(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                tabSelection.selectedTab = .personal
                authViewModel.signIn()
                return
            }
            audioPlayer.play(track: track, in: collection, token: token)
        } else {
            audioPlayer.play(track: track, in: collection, token: nil)
        }

        tabSelection.switchToPlayingTab()
    }
}