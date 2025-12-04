import Foundation

actor CollectionImportService {
    private let client: BaiduNetdiskClient
    private let maxTracksPerCollection = 500

    init(client: BaiduNetdiskClient = BaiduNetdiskClient()) {
        self.client = client
    }

    func buildCollection(
        from path: String,
        title: String?,
        token: BaiduOAuthToken,
        progressHandler: @escaping (Double) async -> Void
    ) async throws -> CollectionDraft {
        // Recursively fetch all files
        let allEntries = try await fetchAllFilesRecursively(path: path, token: token, progressHandler: progressHandler)

        // Filter playable media files (audio + video)
        let mediaEntries = allEntries.filter { entry in
            guard !entry.isDir else { return false }
            let ext = (entry.serverFilename as NSString).pathExtension.lowercased()
            return PlayableMediaFormat.isPlayableExtension(ext)
        }

        // Validate
        guard !mediaEntries.isEmpty else {
            throw CollectionBuildError.noAudioFound
        }

        if mediaEntries.count > maxTracksPerCollection {
            throw CollectionBuildError.tooManyTracks(mediaEntries.count)
        }

        // Sort by path and filename
        let sortedEntries = mediaEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        // Convert to tracks
        var tracks: [AudiobookTrack] = []
        for (index, entry) in sortedEntries.enumerated() {
            let track = AudiobookTrack(
                id: UUID(),
                displayName: entry.serverFilename,
                filename: entry.serverFilename,
                location: .baidu(fsId: entry.fsId, path: entry.path),
                fileSize: entry.size,
                duration: nil,
                trackNumber: index + 1,
                checksum: entry.md5,
                metadata: [:],
                mediaKind: PlayableMediaFormat.mediaKind(forFilename: entry.serverFilename)
            )
            tracks.append(track)
        }

        // Collect non-playable files for info
        let nonPlayableFiles = allEntries
            .filter { !$0.isDir && !PlayableMediaFormat.isPlayableExtension(($0.serverFilename as NSString).pathExtension.lowercased()) }
            .map { $0.serverFilename }

        // Calculate total size
        let totalSize = mediaEntries.reduce(0) { $0 + $1.size }

        // Generate default title
        let defaultTitle = title ?? (path as NSString).lastPathComponent

        // Generate cover suggestion (gradient based on title)
        let coverSuggestion = CollectionCover.generatedCover(for: defaultTitle)

        return CollectionDraft(
            title: defaultTitle,
            folderPath: path,
            tracks: tracks,
            selectedTrackIds: Set(tracks.map(\.id)),          // ALL selected by default
            nonPlayableFiles: nonPlayableFiles,
            totalSize: totalSize,
            coverSuggestion: coverSuggestion
        )
    }

    private func fetchAllFilesRecursively(
        path: String,
        token: BaiduOAuthToken,
        currentProgress: Double = 0.0,
        progressHandler: @escaping (Double) async -> Void
    ) async throws -> [BaiduNetdiskEntry] {
        var allEntries: [BaiduNetdiskEntry] = []
        var directoriesToExplore: [(path: String, depth: Int)] = [(path, 0)]
        let maxDepth = 10 // Prevent infinite recursion

        while !directoriesToExplore.isEmpty {
            let (currentPath, depth) = directoriesToExplore.removeFirst()

            guard depth < maxDepth else { continue }

            // Update progress
            let progress = min(0.9, currentProgress + Double(allEntries.count) / 1000.0)
            await progressHandler(progress)

            // Fetch current directory
            let entries = try await client.listDirectory(path: currentPath, token: token)

            // Separate directories and files
            let (directories, files) = entries.reduce(into: (dirs: [BaiduNetdiskEntry](), files: [BaiduNetdiskEntry]())) { result, entry in
                if entry.isDir {
                    result.dirs.append(entry)
                } else {
                    result.files.append(entry)
                }
            }

            // Add files to results
            allEntries.append(contentsOf: files)

            // Queue subdirectories for exploration
            for dir in directories {
                directoriesToExplore.append((dir.path, depth + 1))
            }
        }
        
        await progressHandler(1.0)

        return allEntries
    }
}
