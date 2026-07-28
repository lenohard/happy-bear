import SwiftUI
#if canImport(UIKit)
import UIKit
import ImageIO
#endif
import UniformTypeIdentifiers

// MARK: - UTType Extension for Drag & Drop
extension UTType {
    static let audiobookCollectionID = UTType(exportedAs: "com.audiobook.collectionID")
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var listenQueueStore: ListenQueueStore

    @State private var activeSource: ImportSource?
    @State private var pendingImport: PendingImport?
    @State private var pendingEbookImport: PendingEbookImport?
    @State private var duplicateImport: DuplicateImportAlert?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var hoveringFolder: UUID?
    @State private var rssUpdates: [UUID: [AudiobookTrack]]?
    @State private var showRSSUpdatesSheet = false
    @State private var isScanningRSS = false
    @State private var rssCheckProgress: String?
    @State private var rssImportSummary: String?
    @State private var showHistorySheet = false
    @State private var searchQuery = ""
    @State private var searchTrackResults: [LibraryStore.FavoriteTrackEntry] = []
    @State private var isSearchingTracks = false
    @State private var searchDebounceTask: Task<Void, Never>?

    private var selectedCollectionID: Binding<UUID?> {
        Binding(
            get: { tabSelection.libraryNavigationTarget },
            set: { tabSelection.libraryNavigationTarget = $0 }
        )
    }

    private var rootCollections: [AudiobookCollection] {
        library.collections.filter { $0.folderId == nil && !$0.isArchived }
    }

    private var eligibleCollectionsForRandomPlay: [AudiobookCollection] {
        library.collections.filter { collection in
            !collection.isArchived
                && collection.trackCount > 0
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                guard authViewModel.token != nil else {
                    tabSelection.selectedTab = .personal
                    authViewModel.signIn()
                    return
                }
                activeSource = .baidu
            } label: {
                Label(NSLocalizedString("baidu_netdisk", comment: "Baidu netdisk source"), systemImage: "icloud")
            }

            Button {
                activeSource = .ebook
            } label: {
                Label(NSLocalizedString("import_ebook_button", value: "Import Ebook", comment: "Import ebook file"), systemImage: "book")
            }

            Button {
                activeSource = .rss
            } label: {
                Label(NSLocalizedString("import_rss_feed_button", value: "Import RSS Feed", comment: "Import RSS feed button"), systemImage: "antenna.radiowaves.left.and.right")
            }

            Button {
                newFolderName = ""
                isCreatingFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        } label: {
            Label(NSLocalizedString("import_button", comment: "Import button"), systemImage: "plus.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.festiveRed : .accentColor)
        }
        .menuStyle(.button)
    }

    private var archivedButton: some View {
        NavigationLink {
            ArchivedCollectionsView()
        } label: {
            Label(NSLocalizedString("archived_collections_title", value: "Archived", comment: "Archived collections view title"), systemImage: "archivebox")
        }
    }

    private var favoritesButton: some View {
        NavigationLink {
            FavoriteTracksView()
        } label: {
            Label(NSLocalizedString("favorite_tracks_title", comment: "Favorite tracks view title"), systemImage: "heart.fill")
        }
        .tint(.red)
    }

    private var queueButton: some View {
        NavigationLink {
            ListenQueueView()
        } label: {
            let count = listenQueueStore.resolvedPending.count
            if count > 0 {
                Label {
                    Text("\(count)")
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            } else {
                Label(
                    NSLocalizedString("queue_title", value: "Listen Queue", comment: "Listen queue view title"),
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
        .tint(.indigo)
    }

    private var historyButton: some View {
        Button {
            showHistorySheet = true
        } label: {
            Label(NSLocalizedString("listening_history", comment: "Listening history section title"), systemImage: "clock.arrow.circlepath")
        }
    }

    private var reloadButton: some View {
        Button {
            Task { await library.load() }
        } label: {
            Label(NSLocalizedString("reload_button", comment: "Reload button"), systemImage: "arrow.clockwise")
        }
    }

    private var checkRSSButton: some View {
        Button {
            checkForRSSUpdates()
        } label: {
            if isScanningRSS {
                ProgressView()
            } else {
                Label(NSLocalizedString("check_rss_updates", value: "Check RSS Updates", comment: "Check RSS updates button"), systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .disabled(isScanningRSS)
    }

    private var randomCollectionButton: some View {
        Button {
            playRandomCollectionFromLibrary()
        } label: {
            Image(systemName: "dice")
        }
        .disabled(eligibleCollectionsForRandomPlay.isEmpty)
        .accessibilityLabel(NSLocalizedString("random_collection", comment: "Random collection button"))
    }

    @ViewBuilder
    private var mainContent: some View {
        Group {
            if library.isLoading {
                LoadingLibraryView()
            } else if !searchQuery.isEmpty {
                searchResultsList
            } else if library.collections.isEmpty && library.folders.isEmpty {
                EmptyLibraryView()
            } else {
                libraryList
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedCollectionID.wrappedValue != nil },
            set: { if !$0 { selectedCollectionID.wrappedValue = nil } }
        )) {
            if let collectionID = selectedCollectionID.wrappedValue {
                CollectionDetailView(collectionID: collectionID)
            }
        }
    }

    private var libraryList: some View {
        List {
            Section(header:
                Text(NSLocalizedString("collections_section", comment: "Collections section title"))
                    .foregroundStyle(themeManager.colors.isFestive ? themeManager.colors.festiveRed : .secondary)
            ) {
                folderRows
                collectionRows
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
        .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
    }


    private var searchResultsList: some View {
        List {
            let lowerQuery = searchQuery.localizedLowercase
            let matchedCollections = library.collections.filter { !$0.isArchived && ($0.title.localizedCaseInsensitiveContains(lowerQuery) || ($0.author?.localizedCaseInsensitiveContains(lowerQuery) ?? false)) }
            
            if !matchedCollections.isEmpty {
                Section(NSLocalizedString("collections_section", value: "Collections", comment: "Collections section")) {
                    ForEach(matchedCollections) { collection in
                        CollectionListRow(
                            collection: collection,
                            selectedCollectionID: selectedCollectionID,
                            onResume: { resumeCollectionPlayback(collection) },
                            onDelete: { library.delete(collection) },
                            onArchive: { withAnimation { library.archiveCollection(collection) } },
                            folders: library.folders,
                            onMoveToFolder: { folder in library.moveCollection(collection, to: folder) },
                            isQueued: listenQueueStore.isQueued(collectionID: collection.id),
                            onToggleQueue: {
                                Task {
                                    if listenQueueStore.isQueued(collectionID: collection.id) {
                                        if let item = listenQueueStore.pendingItems.first(where: { item in
                                            if case .collection(let cid) = item.target { return cid == collection.id }
                                            return false
                                        }) {
                                            await listenQueueStore.remove(itemID: item.id)
                                        }
                                    } else {
                                        await listenQueueStore.addCollection(collection.id)
                                    }
                                }
                            }
                        )
                        .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
                    }
                }
            }

            if isSearchingTracks {
                Section(NSLocalizedString("tracks_section", value: "Tracks", comment: "Tracks section")) {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if !searchTrackResults.isEmpty {
                Section(NSLocalizedString("tracks_section", value: "Tracks", comment: "Tracks section")) {
                    ForEach(searchTrackResults) { entry in
                        FavoriteTrackRow(
                            entry: entry,
                            isActive: audioPlayer.activeCollection?.id == entry.collection.id && audioPlayer.currentTrack?.id == entry.track.id,
                            onPlay: { playTrack(entry.track, in: entry.collection) },
                            onToggleFavorite: {
                                library.toggleFavorite(for: entry.track.id, in: entry.collection.id)
                                audioPlayer.notifyFavoriteToggle(for: entry.track.id)
                            }
                        )
                        .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
                    }
                }
            }
            
            if matchedCollections.isEmpty && searchTrackResults.isEmpty && !isSearchingTracks {
                Text(String(format: NSLocalizedString("no_results_for", value: "No results found for \"%@\"", comment: "No search results message"), searchQuery))
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
        .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var folderRows: some View {
        ForEach(library.folders) { folder in
            FolderListRow(
                folder: folder,
                library: library,
                hoveringFolder: $hoveringFolder,
                onDrop: { providers in handleFolderDrop(providers, into: folder) }
            )
            .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
        }
    }

    @ViewBuilder
    private var collectionRows: some View {
        ForEach(rootCollections) { collection in
            CollectionListRow(
                collection: collection,
                selectedCollectionID: selectedCollectionID,
                onResume: { resumeCollectionPlayback(collection) },
                onDelete: { library.delete(collection) },
                onArchive: { withAnimation { library.archiveCollection(collection) } },
                folders: library.folders,
                onMoveToFolder: { folder in library.moveCollection(collection, to: folder) },
                isQueued: listenQueueStore.isQueued(collectionID: collection.id),
                onToggleQueue: {
                    Task {
                        if listenQueueStore.isQueued(collectionID: collection.id) {
                            if let item = listenQueueStore.pendingItems.first(where: { item in
                                if case .collection(let cid) = item.target { return cid == collection.id }
                                return false
                            }) {
                                await listenQueueStore.remove(itemID: item.id)
                            }
                        } else {
                            await listenQueueStore.addCollection(collection.id)
                        }
                    }
                }
            )
            .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
        }
    }

    var body: some View {
        NavigationStack {
            mainContent
                .navigationTitle(themeManager.colors.isFestive ? "🎄 " + NSLocalizedString("library_title", comment: "Library view title") : NSLocalizedString("library_title", comment: "Library view title"))
                .searchable(text: $searchQuery, prompt: NSLocalizedString("search_library_prompt", value: "Search collections and tracks", comment: "Search prompt in library"))
                .onChange(of: searchQuery) {
                    scheduleLibrarySearch()
                }
                .onSubmit(of: .search) {
                    searchDebounceTask?.cancel()
                    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    Task { await performLibrarySearch(query: query) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        randomCollectionButton
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        checkRSSButton
                        importMenu
                        archivedButton
                        historyButton
                        favoritesButton
                        queueButton
                        reloadButton
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if let progress = rssCheckProgress {
                            Text(progress)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(.regularMaterial)
                                .clipShape(Capsule())
                                .shadow(radius: 2)
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if let message = libraryErrorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color(uiColor: .systemBackground))
                                .overlay(Divider(), alignment: .top)
                        }
                    }
                    .animation(.spring(), value: rssCheckProgress)
                }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                library.createFolder(name: newFolderName)
            }
        }
        .alert(item: $duplicateImport) { duplicate in
            Alert(
                title: Text(NSLocalizedString("duplicate_import_title", comment: "Duplicate import alert title")),
                message: Text(String(format: NSLocalizedString("duplicate_import_message", comment: "Duplicate import message"), duplicate.collection.title)),
                primaryButton: .default(Text(NSLocalizedString("view_collection_button", comment: "View collection button"))) {
                    duplicateImport = nil
                    audioPlayer.loadCollection(duplicate.collection)
                },
                secondaryButton: .default(Text(NSLocalizedString("import_again_button", comment: "Import again button"))) {
                    duplicateImport = nil
                    pendingImport = PendingImport(path: duplicate.path)
                }
            )
        }
        .sheet(isPresented: $showRSSUpdatesSheet, onDismiss: { rssUpdates = nil }) {
            if let updates = rssUpdates {
                RSSUpdatesView(updates: updates) { summary in
                    // Dismiss sheet first, wait for animation, then show the parent-level alert.
                    // Presenting an alert while the sheet dismiss animation is running causes it
                    // to be swallowed on some iOS versions.
                    showRSSUpdatesSheet = false
                    rssUpdates = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        rssImportSummary = summary
                    }
                }
            }
        }
        .alert(
            NSLocalizedString("rss_import_complete_title", value: "Import Complete", comment: "RSS import complete alert title"),
            isPresented: Binding(get: { rssImportSummary != nil }, set: { if !$0 { rssImportSummary = nil } })
        ) {
            Button(NSLocalizedString("ok_button", value: "OK", comment: "OK button")) {
                rssImportSummary = nil
            }
        } message: {
            Text(rssImportSummary ?? "")
        }
        .sheet(item: Binding(
            get: {
                // Only show sheet for .baidu, not for .ebook (handled by fileImporter)
                if case .baidu = activeSource {
                    return activeSource
                }
                return nil
            },
            set: { activeSource = $0 }
        )) { source in
            switch source {
            case .baidu:
                NavigationStack {
                    BaiduNetdiskBrowserView(
                        tokenProvider: { authViewModel.token },
                        onSelectFolder: { path in
                            if let existing = library.collection(forPath: path) {
                                duplicateImport = DuplicateImportAlert(path: path, collection: existing)
                            } else {
                                pendingImport = PendingImport(path: path)
                            }
                            activeSource = nil
                        }
                    )
                }
            case .ebook, .rss:
                EmptyView() // These cases are handled by fileImporter and sheet below
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeSource == .ebook },
                set: { if !$0 { activeSource = nil } }
            ),
            allowedContentTypes: [.epub],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Show preview sheet instead of importing directly
                pendingEbookImport = PendingEbookImport(url: url)
            case .failure(let error):
                AppLog.debug("File picker failed: \(error)")
            }
            activeSource = nil
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { activeSource == .rss },
                set: { if !$0 { activeSource = nil } }
            )
        ) {
            AddRSSCollectionView()
        }
        .sheet(item: $pendingImport) { importSelection in
            CreateCollectionView(
                folderPath: importSelection.path,
                tokenProvider: { authViewModel.token },
                onComplete: { _ in
                    // Collection is automatically added to library,
                    // don't interrupt current playback
                }
            )
        }
        .sheet(item: $pendingEbookImport) { ebookImport in
            CreateEbookCollectionView(
                epubURL: ebookImport.url,
                onComplete: { _ in
                    // Collection is automatically added to library
                }
            )
        }
        .sheet(isPresented: $showHistorySheet) {
            ListeningHistorySheet(
                entries: historySheetEntries,
                onResume: { collection, track in
                    resumeFromHistory(collection: collection, track: track)
                    showHistorySheet = false
                }
            )
        }
    }

    private var historySheetEntries: [ListeningHistoryEntry] {
        buildListeningHistory(from: library, using: audioPlayer)
    }

    private func resumeFromHistory(collection: AudiobookCollection, track: AudiobookTrack) {
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

    private var libraryErrorMessage: String? {
        guard let error = library.lastError else { return nil }
        return error.localizedDescription
    }

    private func resumeCollectionPlayback(_ collection: AudiobookCollection) {
        Task {
            // Ensure collection is loaded before attempting to resume
            await library.ensureCollectionLoaded(collection.id)
            
            await MainActor.run {
                // Get the updated collection from the store
                guard let updatedCollection = library.collections.first(where: { $0.id == collection.id }) else { return }
                guard !updatedCollection.tracks.isEmpty else { return }

                if updatedCollection.isMusic {
                    // For music: Enable shuffle and pick random track
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

    private func playRandomCollectionFromLibrary() {
        guard let randomCollection = eligibleCollectionsForRandomPlay.randomElement() else { return }
        resumeCollectionPlayback(randomCollection)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            guard library.collections.indices.contains(index) else { continue }
            let collection = library.collections[index]
            library.delete(collection)
        }
    }

    private func handleFolderDrop(_ providers: [NSItemProvider], into folder: CollectionFolder) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.audiobookCollectionID.identifier) { data, error in
            guard let data = data,
                  let dragItem = try? JSONDecoder().decode(CollectionDragItem.self, from: data),
                  let collection = library.collections.first(where: { $0.id == dragItem.collectionID }) else {
                return
            }

            DispatchQueue.main.async {
                library.moveCollection(collection, to: folder)
            }
        }

        return true
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

    private func scheduleLibrarySearch() {
        searchDebounceTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchTrackResults = []
            isSearchingTracks = false
            return
        }

        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await performLibrarySearch(query: query)
        }
    }

    @MainActor
    private func performLibrarySearch(query: String) async {
        isSearchingTracks = true
        defer { isSearchingTracks = false }

        do {
            let results = try await library.searchTracks(query: query)
            guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchTrackResults = results
        } catch {
            AppLog.debug("[LibraryView] Track search failed: \(error)")
            searchTrackResults = []
        }
    }

    private func checkForRSSUpdates() {
        let eligibleRSSCollectionCount = library.collections.filter {
            if case .rss = $0.source, $0.autoUpdateEnabled { return true }
            return false
        }.count

        guard eligibleRSSCollectionCount > 0 else {
            audioPlayer.statusMessage = NSLocalizedString(
                "rss_checking_no_collections",
                value: "No RSS collections are enabled for auto-update.",
                comment: "Toast when there are no RSS collections eligible for checking updates"
            )
            return
        }

        isScanningRSS = true
        rssCheckProgress = NSLocalizedString("rss_checking_starting", value: "Starting RSS check...", comment: "RSS check starting")

        Task {
            let updates = await library.scanAllRSSCollections { current, total in
                Task { @MainActor in
                    rssCheckProgress = String(format: NSLocalizedString("rss_checking_progress", value: "Checking %d/%d", comment: "RSS check progress"), current, total)
                }
            }

            await MainActor.run {
                isScanningRSS = false
                rssCheckProgress = nil
                if !updates.isEmpty {
                    rssUpdates = updates
                    showRSSUpdatesSheet = true
                } else {
                    audioPlayer.statusMessage = NSLocalizedString(
                        "rss_checking_no_updates",
                        value: "No new RSS episodes found.",
                        comment: "Toast when RSS update scan finds no new episodes"
                    )
                }
            }
        }
    }
}

// MARK: - Folder Row
private struct FolderListRow: View {
    let folder: CollectionFolder
    @ObservedObject var library: LibraryStore
    @Binding var hoveringFolder: UUID?
    let onDrop: ([NSItemProvider]) -> Bool

    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var isNavigating = false

    private var folderCollections: [AudiobookCollection] {
        library.collections.filter { $0.folderId == folder.id && !$0.isArchived }
    }

    var body: some View {
        FolderGridItemView(
            folder: folder,
            collections: folderCollections,
            isDropTarget: hoveringFolder == folder.id,
            onPlayLast: playLastCollection,
            onPlayRandom: playRandomCollection,
            themeManager: themeManager
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isNavigating = true
        }
        .background(
            NavigationLink(destination: FolderDetailView(folder: folder), isActive: $isNavigating) {
                EmptyView()
            }
            .opacity(0)
        )
        .onDrop(of: [UTType.audiobookCollectionID], isTargeted: Binding(
            get: { hoveringFolder == folder.id },
            set: { isTargeted in hoveringFolder = isTargeted ? folder.id : nil }
        )) { providers in
            onDrop(providers)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                library.deleteFolder(folder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
    }

    private func playLastCollection() {
        guard let lastCollection = folderCollections.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        resumeCollectionPlayback(lastCollection)
    }

    private func playRandomCollection() {
        guard let randomCollection = folderCollections.filter({ !$0.isArchived }).randomElement() else { return }
        resumeCollectionPlayback(randomCollection)
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

// MARK: - Collection Row
private struct CollectionListRow: View {
    let collection: AudiobookCollection
    let selectedCollectionID: Binding<UUID?>
    let onResume: () -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    let folders: [CollectionFolder]
    let onMoveToFolder: (CollectionFolder) -> Void
    let isQueued: Bool
    let onToggleQueue: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            LibraryCollectionRow(collection: collection, isQueued: isQueued)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCollectionID.wrappedValue = collection.id
                }

            Button {
                onResume()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: NSLocalizedString("play_collection_accessibility", comment: "Play collection accessibility label"), collection.title))
            .frame(width: 56, alignment: .trailing)
        }
        .draggable(CollectionDragItem(collection: collection))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                onToggleQueue()
            } label: {
                Label(
                    isQueued
                        ? NSLocalizedString("remove_from_queue", value: "Remove from Queue", comment: "Remove from listen queue")
                        : NSLocalizedString("add_to_queue", value: "Add to Queue", comment: "Add to listen queue"),
                    systemImage: isQueued ? "text.badge.minus" : "text.badge.plus"
                )
            }
            .labelStyle(.iconOnly)
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("delete_button", comment: "Delete button"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            
            Button {
                onArchive()
            } label: {
                Image(systemName: "archivebox")
            }
            .tint(.orange)
        }
        .contextMenu {
            if !folders.isEmpty {
                Section("Move to Folder") {
                    ForEach(folders) { folder in
                        Button {
                            onMoveToFolder(folder)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
            }
        }
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(NSLocalizedString("empty_library_message", comment: "Empty library message"))
                .font(.title3)
                .bold()

            Text(NSLocalizedString("empty_library_hint", comment: "Empty library hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct LoadingLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)

            Text(NSLocalizedString("loading_library", comment: "Loading library message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private enum ImportSource: Identifiable {
    case baidu
    case ebook
    case rss

    var id: String {
        switch self {
        case .baidu:
            return "baidu"
        case .ebook:
            return "ebook"
        case .rss:
            return "rss"
        }
    }
}

private struct DuplicateImportAlert: Identifiable {
    let path: String
    let collection: AudiobookCollection

    var id: UUID { collection.id }
}

private struct PendingImport: Identifiable {
    let path: String
    var id: String { path }
}

private struct PendingEbookImport: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Folder Views

// MARK: - Drag & Drop support

private struct CollectionDragItem: Codable, Transferable {
    let collectionID: UUID

    init(collection: AudiobookCollection) {
        self.collectionID = collection.id
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .audiobookCollectionID)
    }
}

struct FolderGridItemView: View {
    let folder: CollectionFolder
    let collections: [AudiobookCollection]
    var isDropTarget: Bool = false
    let onPlayLast: () -> Void
    let onPlayRandom: () -> Void
    var themeManager: ThemeManager?

    private var collectionCount: Int {
        collections.count
    }

    private var countText: String {
        let collectionText = collectionCount == 1 ? "collection" : "collections"
        return "\(collectionCount) \(collectionText)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Folder icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        (themeManager?.colors.isFestive == true ? themeManager?.colors.festiveRed.opacity(0.1) : Color.blue.opacity(0.1)) ?? Color.blue.opacity(0.1)
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(
                        (themeManager?.colors.isFestive == true ? themeManager?.colors.festiveRed : .blue) ?? .blue
                    )
            }

            // Title and count
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action buttons - fixed width to align with collection rows
            HStack(spacing: 8) {
                Button {
                    onPlayRandom()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .disabled(collections.isEmpty)

                Button {
                    onPlayLast()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(collections.isEmpty)
            }
            .frame(width: 56, alignment: .trailing)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct FolderDetailView: View {
    let folder: CollectionFolder
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tabSelection: TabSelectionManager
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var isRenaming = false
    @State private var newName = ""
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var folderCollections: [AudiobookCollection] {
        library.collections.filter { $0.folderId == folder.id && !$0.isArchived }
    }

    var body: some View {
        List {
            ForEach(folderCollections) { collection in
                HStack(spacing: 12) {
                    LibraryCollectionRow(collection: collection)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tabSelection.libraryNavigationTarget = collection.id
                        }

                    Button {
                        resumeCollectionPlayback(collection)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.delete(collection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)

                    Button {
                        withAnimation {
                            library.archiveCollection(collection)
                        }
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .tint(.orange)

                    Button {
                        library.moveCollection(collection, to: nil) // Move to root
                    } label: {
                        Image(systemName: "arrow.turn.up.left")
                    }
                    .tint(.blue)
                }
                .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
        .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newName = folder.name
                        isRenaming = true
                    } label: {
                        Label("Rename Folder", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Folder", isPresented: $isRenaming) {
            TextField("Folder Name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                library.renameFolder(folder, to: newName)
            }
        }
        .alert("Delete Folder", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                library.deleteFolder(folder)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete this folder? Collections inside will be moved to the main library.")
        }
    }

    private func resumeCollectionPlayback(_ collection: AudiobookCollection) {
        Task {
            await library.ensureCollectionLoaded(collection.id)
            await MainActor.run {
                guard let updatedCollection = library.collections.first(where: { $0.id == collection.id }) else { return }
                guard !updatedCollection.tracks.isEmpty else {
                    audioPlayer.statusMessage = "\"\(updatedCollection.title)\" has no tracks to play."
                    return
                }

                if updatedCollection.isMusic {
                    var collectionToPlay = updatedCollection
                    if !collectionToPlay.shuffleEnabled {
                        library.updateShuffle(true, for: collectionToPlay.id)
                        collectionToPlay.shuffleEnabled = true
                    }
                    guard let randomTrack = collectionToPlay.tracks.randomElement() else {
                        audioPlayer.statusMessage = "Unable to pick a random track."
                        return
                    }
                    playTrack(randomTrack, in: collectionToPlay)
                } else {
                    guard let track = updatedCollection.resumeTrack() else {
                        audioPlayer.statusMessage = "Unable to find a track to resume."
                        return
                    }
                    playTrack(track, in: updatedCollection)
                }
            }
        }
    }

    private func playTrack(_ track: AudiobookTrack, in collection: AudiobookCollection) {
        if case .baiduNetdisk(_, _) = collection.source {
            guard let token = authViewModel.token else {
                audioPlayer.statusMessage = NSLocalizedString("connect_baidu_before_stream", comment: "Alert message to sign in before streaming")
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

// MARK: - Shared Views

struct LibraryCollectionRow: View {
    let collection: AudiobookCollection
    var isQueued: Bool = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var subtitle: String {
        let trackCount = collection.trackCount
        let updated = Self.dateFormatter.string(from: collection.updatedAt)

        if trackCount == 1 {
            return "1 track • Updated \(updated)"
        } else {
            return "\(trackCount) tracks • Updated \(updated)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            coverView

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    inlineCollectionTitle(for: collection)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isQueued {
                        Image(systemName: "list.bullet")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                            .accessibilityLabel(Text(NSLocalizedString("queue_badge_accessibility", value: "In Listen Queue", comment: "Accessibility label for listen queue badge")))
                    }
                }
                if let author = collection.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func inlineCollectionTitle(for collection: AudiobookCollection) -> Text {
        let title = Text(collection.title)

        if case .ebook = collection.source {
            return coloredIconText("book", color: .blue) + Text(" ") + title
        } else if case .rss = collection.source {
            return coloredIconText("antenna.radiowaves.left.and.right", color: .orange) + Text(" ") + title
        } else if collection.isMusic {
            return coloredIconText("music.note", color: .pink) + Text(" ") + title
        }

        return title
    }

    private func coloredIconText(_ systemName: String, color: Color) -> Text {
        Text(Image(systemName: systemName)).foregroundStyle(color)
    }

    private var coverView: some View {
        CollectionCoverArtView(
            cover: collection.coverAsset,
            title: collection.title,
            size: 56,
            cornerRadius: 8
        )
    }
}

struct CollectionCoverArtView: View {
    let cover: CollectionCover
    let title: String
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    @State private var localImage: UIImage?
    @State private var cachedRelativePath: String?
    @State private var loadTask: Task<Void, Never>?

    // Cache for small thumbnails to avoid repeated resizing - shared for preloading
    nonisolated(unsafe) static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    var body: some View {
        ZStack {
            switch cover.kind {
            case .solid(let colorHex):
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(hexString: colorHex))
                    .overlay(initialsOverlay)
            case .image:
                imageOverlay
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder(symbol: "icloud.and.arrow.down", tint: Color.blue.opacity(0.3))
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.1))
                            )
                    case .failure:
                        placeholder(symbol: "exclamationmark.triangle", tint: Color.red.opacity(0.3))
                    @unknown default:
                        placeholder(symbol: "questionmark", tint: Color.gray.opacity(0.3))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { refreshImageIfNeeded(force: false) }
        .onChange(of: cover) { refreshImageIfNeeded(force: true) }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private var initialsOverlay: some View {
        Text(makeInitials(from: title))
            .font(.headline)
            .foregroundStyle(.white)
    }

    private var imageOverlay: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(symbol: "photo", tint: Color.gray.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1))
        )
    }

    private func placeholder(symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
            .overlay(
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            )
    }

	    private func refreshImageIfNeeded(force: Bool = false) {
	        guard case let .image(relativePath) = cover.kind else {
	            localImage = nil
	            cachedRelativePath = nil
	            return
	        }

        // If we already have this image loaded, skip
        guard force || cachedRelativePath != relativePath || localImage == nil else { return }

	        let cacheKey = relativePath as NSString
	        cachedRelativePath = relativePath
	
	        // 1. Check thumbnail cache first (fastest) - this is the hot path during scroll
	        if size <= 160, let cachedThumbnail = Self.thumbnailCache.object(forKey: cacheKey) {
	            localImage = cachedThumbnail
	            return
	        }

#if canImport(UIKit)
	        let targetMaxPixelSize = max(320, size * UIScreen.main.scale)
#else
	        let targetMaxPixelSize: CGFloat = 320
#endif
	
	        // 2. Disk load - defer to background, don't block scroll
	        // Only spawn task if we don't already have one running for this path
	        loadTask?.cancel()
	
	        loadTask = Task.detached(priority: .utility) {
	            let url = CollectionCoverImageStore.fileURL(for: relativePath)
	            guard let thumbnail = Self.downsampleCoverImage(at: url, maxPixelSize: targetMaxPixelSize) else { return }
	            Self.thumbnailCache.setObject(thumbnail, forKey: cacheKey)
	
	            guard !Task.isCancelled else { return }
	
	            await MainActor.run {
	                if self.cachedRelativePath == relativePath {
	                    self.localImage = thumbnail
	                }
	            }
	        }
	    }

#if canImport(UIKit)
	    private static func downsampleCoverImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
	        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
	        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

	        let options = [
	            kCGImageSourceCreateThumbnailFromImageAlways: true,
	            kCGImageSourceCreateThumbnailWithTransform: true,
	            kCGImageSourceShouldCacheImmediately: true,
	            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
	        ] as CFDictionary

	        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
	        return UIImage(cgImage: cgImage)
	    }
#endif

    private func makeInitials(from text: String) -> String {
        let words = text.split(separator: " ")
        let firstLetters = words.prefix(2).compactMap { $0.first }
        if firstLetters.isEmpty {
            return "AB"
        }
        return firstLetters.map(String.init).joined().uppercased()
    }
}

// MARK: - Previews

#Preview("Folder Grid Item") {
    let folder = CollectionFolder(
        id: UUID(),
        name: "Podcasts",
        createdAt: Date(),
        updatedAt: Date()
    )

    let sampleCollections = [
        AudiobookCollection(
            id: UUID(),
            title: "Sample Book 1",
            author: "Author Name",
            description: nil,
            coverAsset: CollectionCover.generatedCover(for: "Sample Book 1"),
            createdAt: Date(),
            updatedAt: Date(),
            source: .external(description: "Preview"),
            tracks: [],
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: [],
            trackCount: 12,
            folderId: folder.id
        ),
        AudiobookCollection(
            id: UUID(),
            title: "Sample Book 2",
            author: "Another Author",
            description: nil,
            coverAsset: CollectionCover.generatedCover(for: "Sample Book 2"),
            createdAt: Date(),
            updatedAt: Date(),
            source: .external(description: "Preview"),
            tracks: [],
            lastPlayedTrackId: nil,
            playbackStates: [:],
            tags: [],
            trackCount: 8,
            folderId: folder.id
        )
    ]

    List {
        FolderGridItemView(
            folder: folder,
            collections: sampleCollections,
            isDropTarget: false,
            onPlayLast: {},
            onPlayRandom: {}
        )

        FolderGridItemView(
            folder: CollectionFolder(name: "Empty Folder"),
            collections: [],
            isDropTarget: false,
            onPlayLast: {},
            onPlayRandom: {}
        )

        FolderGridItemView(
            folder: CollectionFolder(name: "Drop Target"),
            collections: sampleCollections,
            isDropTarget: true,
            onPlayLast: {},
            onPlayRandom: {}
        )
    }
    .listStyle(.insetGrouped)
}

#Preview("Library View") {
    let library = LibraryStore(autoLoadOnInit: false)
    let audioPlayer = AudioPlayerViewModel()
    let authViewModel = BaiduAuthViewModel()
    let tabSelection = TabSelectionManager()

    // Create sample folders
    let _ = library.createFolder(name: "Podcasts")
    let _ = library.createFolder(name: "Music Albums")

    let podcastFolder = library.folders.first { $0.name == "Podcasts" }!
    let musicFolder = library.folders.first { $0.name == "Music Albums" }!

    // Create sample collections
    let _ = library.save(AudiobookCollection(
        id: UUID(),
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        description: "A fantasy adventure novel",
        coverAsset: CollectionCover.generatedCover(for: "The Hobbit"),
        createdAt: Date().addingTimeInterval(-86400 * 10),
        updatedAt: Date().addingTimeInterval(-86400 * 2),
        source: .external(description: "Library"),
        tracks: [],
        lastPlayedTrackId: nil,
        playbackStates: [:],
        tags: ["fantasy"],
        trackCount: 19,
        folderId: nil
    ))

    let _ = library.save(AudiobookCollection(
        id: UUID(),
        title: "1984",
        author: "George Orwell",
        description: "Dystopian social science fiction",
        coverAsset: CollectionCover.generatedCover(for: "1984"),
        createdAt: Date().addingTimeInterval(-86400 * 20),
        updatedAt: Date().addingTimeInterval(-86400 * 1),
        source: .external(description: "Library"),
        tracks: [],
        lastPlayedTrackId: nil,
        playbackStates: [:],
        tags: ["scifi"],
        trackCount: 12,
        folderId: nil
    ))

    let _ = library.save(AudiobookCollection(
        id: UUID(),
        title: "Podcast Episode 42",
        author: "Tech Talk",
        description: nil,
        coverAsset: CollectionCover.generatedCover(for: "Tech Talk"),
        createdAt: Date().addingTimeInterval(-86400 * 15),
        updatedAt: Date().addingTimeInterval(-86400 * 3),
        source: .rss(feedUrl: URL(string: "https://example.com/feed")!),
        tracks: [],
        lastPlayedTrackId: nil,
        playbackStates: [:],
        tags: [],
        trackCount: 1,
        folderId: podcastFolder.id
    ))

    let _ = library.save(AudiobookCollection(
        id: UUID(),
        title: "Album - Greatest Hits",
        author: "Sample Artist",
        description: nil,
        coverAsset: CollectionCover.generatedCover(for: "Greatest Hits"),
        createdAt: Date().addingTimeInterval(-86400 * 45),
        updatedAt: Date().addingTimeInterval(-86400 * 7),
        source: .external(description: "Music"),
        tracks: [],
        lastPlayedTrackId: nil,
        playbackStates: [:],
        tags: [],
        trackCount: 15,
        isMusic: true,
        folderId: musicFolder.id
    ))

    LibraryView()
        .environmentObject(library)
        .environmentObject(audioPlayer)
        .environmentObject(authViewModel)
        .environmentObject(tabSelection)
}
