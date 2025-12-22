import SwiftUI
#if canImport(UIKit)
import UIKit
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

    @State private var activeSource: ImportSource?
    @State private var pendingImport: PendingImport?
    @State private var pendingEbookImport: PendingEbookImport?
    @State private var duplicateImport: DuplicateImportAlert?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var hoveringFolder: UUID?

    private var selectedCollectionID: Binding<UUID?> {
        Binding(
            get: { tabSelection.libraryNavigationTarget },
            set: { tabSelection.libraryNavigationTarget = $0 }
        )
    }

    private var rootCollections: [AudiobookCollection] {
        library.collections.filter { $0.folderId == nil }
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
        }
        .menuStyle(.button)
    }

    private var favoritesButton: some View {
        NavigationLink {
            FavoriteTracksView()
        } label: {
            Label(NSLocalizedString("favorite_tracks_title", comment: "Favorite tracks view title"), systemImage: "heart.fill")
        }
        .tint(.red)
    }

    private var reloadButton: some View {
        Button {
            Task { await library.load() }
        } label: {
            Label(NSLocalizedString("reload_button", comment: "Reload button"), systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if library.isLoading {
            LoadingLibraryView()
        } else if library.collections.isEmpty && library.folders.isEmpty {
            EmptyLibraryView()
        } else {
            libraryList
        }
    }

    private var libraryList: some View {
        List {
            Section(NSLocalizedString("collections_section", comment: "Collections section title")) {
                folderRows
                collectionRows
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(isPresented: Binding(
            get: { selectedCollectionID.wrappedValue != nil },
            set: { if !$0 { selectedCollectionID.wrappedValue = nil } }
        )) {
            if let collectionID = selectedCollectionID.wrappedValue {
                CollectionDetailView(collectionID: collectionID)
            }
        }
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
                folders: library.folders,
                onMoveToFolder: { folder in library.moveCollection(collection, to: folder) }
            )
        }
    }

    var body: some View {
        NavigationStack {
            mainContent
                .navigationTitle(NSLocalizedString("library_title", comment: "Library view title"))
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        importMenu
                        favoritesButton
                        reloadButton
                    }
                }
                .overlay(alignment: .bottom) {
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
                print("File picker failed: \(error)")
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
}

// MARK: - Folder Row
private struct FolderListRow: View {
    let folder: CollectionFolder
    @ObservedObject var library: LibraryStore
    @Binding var hoveringFolder: UUID?
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        NavigationLink(destination: FolderDetailView(folder: folder)) {
            FolderGridItemView(
                folder: folder,
                count: library.collections.filter { $0.folderId == folder.id }.count,
                isDropTarget: hoveringFolder == folder.id
            )
        }
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
        }
    }
}

// MARK: - Collection Row
private struct CollectionListRow: View {
    let collection: AudiobookCollection
    let selectedCollectionID: Binding<UUID?>
    let onResume: () -> Void
    let onDelete: () -> Void
    let folders: [CollectionFolder]
    let onMoveToFolder: (CollectionFolder) -> Void

    var body: some View {
        HStack(spacing: 12) {
            LibraryCollectionRow(collection: collection)
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
        }
        .draggable(CollectionDragItem(collection: collection))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("delete_button", comment: "Delete button"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
        .contextMenu {
            Menu("Move to Folder") {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        onMoveToFolder(folder)
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
    let count: Int
    var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 56, height: 56)

                Image(systemName: "folder.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
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

    @State private var isRenaming = false
    @State private var newName = ""
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var folderCollections: [AudiobookCollection] {
        library.collections.filter { $0.folderId == folder.id }
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
                        library.moveCollection(collection, to: nil) // Move to root
                    } label: {
                        Label("Move Out", systemImage: "arrow.turn.up.left")
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
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

// MARK: - Shared Views

struct LibraryCollectionRow: View {
    let collection: AudiobookCollection

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

        // 2. Check main cache - also fast, no disk I/O
        if let cached = CollectionCoverImageStore.cache.object(forKey: cacheKey) {
            localImage = cached
            // Generate thumbnail in background for next time (non-blocking)
            if size <= 160 {
                generateThumbnail(from: cached, key: cacheKey)
            }
            return
        }

        // 3. Disk load - defer to background, don't block scroll
        // Only spawn task if we don't already have one running for this path
        loadTask?.cancel()

        loadTask = Task.detached(priority: .utility) {
            let url = CollectionCoverImageStore.fileURL(for: relativePath)
            guard let image = UIImage(contentsOfFile: url.path) else { return }

            // Cache full image
            CollectionCoverImageStore.cache.setObject(image, forKey: cacheKey)

            // Generate and cache thumbnail
            let thumbnail = image.redraw(to: CGSize(width: 320, height: 320))
            Self.thumbnailCache.setObject(thumbnail, forKey: cacheKey)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if self.cachedRelativePath == relativePath {
                    self.localImage = self.size <= 160 ? thumbnail : image
                }
            }
        }
    }

    private func generateThumbnail(from image: UIImage, key: NSString) {
        Task.detached(priority: .background) {
            let targetSize = CGSize(width: 320, height: 320)
            let thumbnail = image.redraw(to: targetSize)
            Self.thumbnailCache.setObject(thumbnail, forKey: key)
        }
    }

    private func makeInitials(from text: String) -> String {
        let words = text.split(separator: " ")
        let firstLetters = words.prefix(2).compactMap { $0.first }
        if firstLetters.isEmpty {
            return "AB"
        }
        return firstLetters.map(String.init).joined().uppercased()
    }
}

