import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel

    @State private var activeSource: ImportSource?
    @State private var pendingImport: PendingImport?
    @State private var missingAuthAlert = false
    @State private var duplicateImport: DuplicateImportAlert?

    var body: some View {
        NavigationStack {
            Group {
                if library.collections.isEmpty {
                    EmptyLibraryView()
                } else {
                    List {
                        Section("Collections") {
                            ForEach(library.collections) { collection in
                                NavigationLink {
                                    CollectionDetailView(collectionID: collection.id)
                                } label: {
                                    LibraryCollectionRow(collection: collection)
                                }
                            }
                            .onDelete(perform: delete)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Baidu Netdisk") {
                            guard authViewModel.token != nil else {
                                missingAuthAlert = true
                                return
                            }
                            activeSource = .baidu
                        }
                    } label: {
                        Label("Import", systemImage: "tray.and.arrow.down")
                    }

                    Button {
                        Task { await library.load() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
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
        .alert("Connect Baidu First", isPresented: $missingAuthAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Open the Sources tab to sign in with your Baidu account before importing.")
        }
        .alert(item: $duplicateImport) { duplicate in
            Alert(
                title: Text("Already Imported"),
                message: Text("“\(duplicate.collection.title)” already uses this folder. What would you like to do?"),
                primaryButton: .default(Text("View Collection")) {
                    duplicateImport = nil
                    audioPlayer.loadCollection(duplicate.collection)
                },
                secondaryButton: .default(Text("Import Again")) {
                    duplicateImport = nil
                    pendingImport = PendingImport(path: duplicate.path)
                }
            )
        }
        .sheet(item: $activeSource) { source in
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
            }
        }
        .sheet(item: $pendingImport) { importSelection in
            CreateCollectionView(
                folderPath: importSelection.path,
                tokenProvider: { authViewModel.token },
                onComplete: { collection in
                    audioPlayer.loadCollection(collection)
                }
            )
        }
    }

    private var libraryErrorMessage: String? {
        guard let error = library.lastError else { return nil }
        return error.localizedDescription
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            guard library.collections.indices.contains(index) else { continue }
            let collection = library.collections[index]
            library.delete(collection)
        }
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Your library is empty")
                .font(.title3)
                .bold()

            Text("Tap “Import” to choose a source and add your first audiobook collection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct LibraryCollectionRow: View {
    let collection: AudiobookCollection

    private var subtitle: String {
        let trackCount = collection.tracks.count
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let updated = formatter.string(from: collection.updatedAt)

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
                Text(collection.title)
                    .font(.headline)
                    .lineLimit(2)

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

    @ViewBuilder
    private var coverView: some View {
        switch collection.coverAsset.kind {
        case .solid(let colorHex):
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: colorHex))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(collection.initials)
                        .font(.headline)
                        .foregroundStyle(.white)
                )
        case .image:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
        case .remote:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.3))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: sanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64

        switch sanitized.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 91, 141, 239) // default fallback color (#5B8DEF)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
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

#Preview {
    let sample = AudiobookCollection.makeEmptyDraft(
        for: .baiduNetdisk(folderPath: "/audiobooks", tokenScope: "netdisk"),
        title: "Sample Collection"
    )

    let store = LibraryStore(
        persistence: LibraryPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("library-preview.json")),
        autoLoadOnInit: false
    )
    store.save(sample)

    return LibraryView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(store)
        .environmentObject(BaiduAuthViewModel())
}

private enum ImportSource: Identifiable {
    case baidu

    var id: String {
        switch self {
        case .baidu:
            return "baidu"
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
