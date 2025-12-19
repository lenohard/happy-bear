import SwiftUI

struct StorageManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var library: LibraryStore
    
    @State private var retentionDays: Int = 0
    @State private var showClearAllConfirmation = false
    @State private var collectionSizes: [UUID: Int64] = [:]
    @State private var isLoadingSizes = true
    @State private var collectionToDelete: AudiobookCollection?
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            cacheSection
            
            collectionsSection
        }
        .navigationTitle(NSLocalizedString("storage_management_title", value: "Storage Management", comment: "Storage management title"))
        .onAppear {
            retentionDays = audioPlayer.cacheRetentionDays()
            calculateSizes()
        }
        .confirmationDialog(
            NSLocalizedString("cache_clear_all_title", comment: "Clear cached audio confirmation title"),
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("cache_clear_all_confirm", comment: "Delete all cached audio button"), role: .destructive) {
                audioPlayer.clearAllCache()
                calculateSizes()
            }
            Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("cache_clear_all_message", comment: "Clear all cached audio confirmation message"))
        }
        .alert(
            "Delete Storage for Collection",
            isPresented: $showDeleteConfirmation,
            presenting: collectionToDelete
        ) { collection in
            Button("Delete Storage", role: .destructive) {
                deleteStorage(for: collection)
                collectionToDelete = nil
                showDeleteConfirmation = false
            }
            Button("Cancel", role: .cancel) {
                collectionToDelete = nil
                showDeleteConfirmation = false
            }
        } message: { collection in
            Text("Are you sure you want to delete all downloaded/cached audio for '\(collection.title)'? This action cannot be undone.")
        }
    }
    
    private var cacheSection: some View {
        Section(NSLocalizedString("cache_storage_section", comment: "Storage section title")) {
            HStack {
                Text(NSLocalizedString("cache_total_size", comment: "Total cache size label"))
                Spacer()
                Text(audioPlayer.formattedCacheSize())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("cache_folder", comment: "Cache folder label"))
                Text(audioPlayer.cacheDirectoryPath())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Stepper(value: $retentionDays, in: 1...30, step: 1) {
                Text(String(format: NSLocalizedString("cache_retention_days", comment: "Cache retention days format"), retentionDays, retentionDays == 1 ? NSLocalizedString("cache_day", comment: "Day") : NSLocalizedString("cache_days", comment: "Days")))
            }
            .onChange(of: retentionDays) { newValue in
                audioPlayer.updateCacheRetention(days: newValue)
            }

            Button(role: .destructive) {
                showClearAllConfirmation = true
            } label: {
                Label(NSLocalizedString("cache_clear_all", comment: "Clear all cached audio"), systemImage: "trash.slash")
            }
        }
    }
    
    private var collectionsSection: some View {
        Section("Per-Collection Storage") {
            if isLoadingSizes {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                let filteredCollections = library.collections.filter { (collectionSizes[$0.id] ?? 0) > 0 }
                
                if filteredCollections.isEmpty {
                    Text("No collections using storage")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredCollections) { collection in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(collection.title)
                                    .font(.headline)
                                Text("\(collection.tracks.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if let size = collectionSizes[collection.id] {
                                Text(formatBytes(size))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("--")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                collectionToDelete = collection
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func calculateSizes() {
        Task {
            await MainActor.run {
                isLoadingSizes = true
            }

            var sizes: [UUID: Int64] = [:]

            for collection in await library.collections {
                // Calculate size:
                // 1. Local files (if source is local) - usually just track file sizes
                // 2. Cached files (if source is Baidu/External/Ebook) - query cache manager

                var size: Int64 = 0

                // For local collections, track.fileSize is the actual size on disk
                if case .local = collection.source {
                    size = collection.tracks.reduce(0) { $0 + $1.fileSize }
                } else {
                    // For remote/ebook, check cache
                    let trackIds = collection.tracks.map { $0.id.uuidString }
                    size = await audioPlayer.getCollectionCacheSize(trackIds: trackIds)
                }

                sizes[collection.id] = size
            }

            await MainActor.run {
                collectionSizes = sizes
                isLoadingSizes = false
            }
        }
    }
    
    private func deleteStorage(for collection: AudiobookCollection) {
        Task {
            let trackIds = collection.tracks.map { $0.id.uuidString }
            await audioPlayer.removeCollectionCache(trackIds: trackIds)
            calculateSizes()
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
