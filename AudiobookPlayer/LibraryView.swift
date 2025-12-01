import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var tabSelection: TabSelectionManager

    @State private var activeSource: ImportSource?
    @State private var pendingImport: PendingImport?
    @State private var pendingEbookImport: PendingEbookImport?
    @State private var duplicateImport: DuplicateImportAlert?
    
    private var selectedCollectionID: Binding<UUID?> {
        Binding(
            get: { tabSelection.libraryNavigationTarget },
            set: { tabSelection.libraryNavigationTarget = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.isLoading {
                    LoadingLibraryView()
                } else if library.collections.isEmpty {
                    EmptyLibraryView()
                } else {
                    List {
                        Section(NSLocalizedString("collections_section", comment: "Collections section title")) {
                            ForEach(library.collections) { collection in
                                ZStack {
                                    // Hidden NavigationLink for isActive binding
                                    NavigationLink(
                                        isActive: Binding(
                                            get: { selectedCollectionID.wrappedValue == collection.id },
                                            set: { isActive in
                                                if isActive {
                                                    selectedCollectionID.wrappedValue = collection.id
                                                } else {
                                                    selectedCollectionID.wrappedValue = nil
                                                }
                                            }
                                        )
                                    ) {
                                        CollectionDetailView(collectionID: collection.id)
                                    } label: {
                                        EmptyView()
                                    }
                                    .hidden()

                                    HStack(spacing: 12) {
                                        LibraryCollectionRow(collection: collection)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                selectedCollectionID.wrappedValue = collection.id
                                            }

                                        Button {
                                            resumeCollectionPlayback(collection)
                                        } label: {
                                            Image(systemName: "play.circle.fill")
                                                .font(.title3)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(String(format: NSLocalizedString("play_collection_accessibility", comment: "Play collection accessibility label"), collection.title))
                                    }
                                }
                            }
                            .onDelete(perform: delete)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(NSLocalizedString("library_title", comment: "Library view title"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button(NSLocalizedString("baidu_netdisk", comment: "Baidu netdisk source")) {
                            guard authViewModel.token != nil else {
                                tabSelection.selectedTab = .personal
                                authViewModel.signIn()
                                return
                            }
                            activeSource = .baidu
                        }
                        
                        Button("Import Ebook") {
                            activeSource = .ebook
                        }
                    } label: {
                        Label(NSLocalizedString("import_button", comment: "Import button"), systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .menuStyle(.button)

                    NavigationLink {
                        FavoriteTracksView()
                    } label: {
                        Label(NSLocalizedString("favorite_tracks_title", comment: "Favorite tracks view title"), systemImage: "heart.fill")
                    }
                    .tint(.red)

                    Button {
                        Task { await library.load() }
                    } label: {
                        Label(NSLocalizedString("reload_button", comment: "Reload button"), systemImage: "arrow.clockwise")
                    }
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
            case .ebook:
                EmptyView() // This case should never be reached
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
        guard !collection.tracks.isEmpty else { return }
        guard let track = collection.resumeTrack() else { return }
        playTrack(track, in: collection)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            guard library.collections.indices.contains(index) else { continue }
            let collection = library.collections[index]
            library.delete(collection)
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

private struct LibraryCollectionRow: View {
    let collection: AudiobookCollection

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var subtitle: String {
        let trackCount = collection.tracks.count
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
                    Text(collection.title)
                        .font(.headline)
                        .lineLimit(2)
                    if case .ebook = collection.source {
                        Image(systemName: "book")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                            .accessibilityLabel(NSLocalizedString("ebook_collection_indicator_accessibility", comment: "Indicator for ebook collection"))
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

    private var coverView: some View {
        CollectionCoverArtView(
            cover: collection.coverAsset,
            title: collection.title,
            size: 56,
            cornerRadius: 8
        )
    }
}



private extension AudiobookCollection {
    var initials: String {
        let words = title.split(separator: " ")
        let firstLetters = words.prefix(2).compactMap { $0.first }
        if firstLetters.isEmpty {
            return "AB"
        }
        return firstLetters.map(String.init).joined().uppercased()
    }
}

struct CollectionCoverArtView: View {
    let cover: CollectionCover
    let title: String
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    @State private var localImage: UIImage?
    @State private var cachedRelativePath: String?

    var body: some View {
        ZStack {
            switch cover.kind {
            case .solid(let colorHex):
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(hexString: colorHex))
                    .overlay(initialsOverlay)
            case .image:
                imageOverlay
            case .remote:
                placeholder(symbol: "icloud.and.arrow.down", tint: Color.blue.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { refreshImageIfNeeded(force: true) }
        .onChange(of: cover) { _ in refreshImageIfNeeded(force: true) }
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

        guard force || cachedRelativePath != relativePath else { return }
        cachedRelativePath = relativePath

        Task.detached(priority: .utility) {
            let url = CollectionCoverImageStore.fileURL(for: relativePath)
            let image = UIImage(contentsOfFile: url.path)
            await MainActor.run {
                self.localImage = image
            }
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

// Preview disabled - complex initialization conflicts with type inference
// Re-enable when GRDBDatabaseManager preview support is added
/*
#Preview("LibraryView") {
    let sample = AudiobookCollection.makeEmptyDraft(
        for: .baiduNetdisk(folderPath: "/audiobooks", tokenScope: "netdisk"),
        title: "Sample Collection"
    )

    let store = LibraryStore(
        dbManager: .shared,
        jsonPersistence: LibraryPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("library-preview.json")),
        autoLoadOnInit: false
    )
    store.save(sample)

    LibraryView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(store)
        .environmentObject(BaiduAuthViewModel())
}
*/

private enum ImportSource: Identifiable {
    case baidu
    case ebook

    var id: String {
        switch self {
        case .baidu:
            return "baidu"
        case .ebook:
            return "ebook"
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
