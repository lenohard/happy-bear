import Foundation
import Combine

enum CollectionBuildError: LocalizedError {
    case noAudioFound
    case tooManyTracks(Int)
    case expiredToken
    case networkFailure(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .noAudioFound:
            return "No playable audio or video files found in this folder"
        case .tooManyTracks(let count):
            return "Too many tracks (\(count)). Maximum is 500 tracks per collection."
        case .expiredToken:
            return "Baidu token expired. Please re-authenticate."
        case .networkFailure(let error):
            return "Network error: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}

struct CollectionDraft {
    var title: String
    var folderPath: String
    var tracks: [AudiobookTrack]           // ALL discovered tracks
    var selectedTrackIds: Set<UUID>        // Phase 1: tracks user selected
    var nonPlayableFiles: [String]
    var totalSize: Int64
    var coverSuggestion: CollectionCover

    /// Returns only SELECTED tracks (what gets saved to collection)
    var selectedTracks: [AudiobookTrack] {
        tracks.filter { selectedTrackIds.contains($0.id) }
    }

    /// Returns count of selected tracks (for UI display)
    var selectedTrackCount: Int {
        selectedTrackIds.count
    }

    /// Returns total discovered track count (for UI "X of Y" display)
    var totalTrackCount: Int {
        tracks.count
    }
}

final class CollectionBuilderViewModel: ObservableObject {
    enum State {
        case idle
        case loading(Double)
        case ready(CollectionDraft)
        case failed(CollectionBuildError)
    }

    @MainActor @Published private(set) var state: State = .idle

    private let client: BaiduNetdiskClient
    private let maxTracksPerCollection = 10000

    init(client: BaiduNetdiskClient = BaiduNetdiskClient()) {
        self.client = client
    }

    func buildCollection(
        from path: String,
        title: String?,
        tokenProvider: @escaping () -> BaiduOAuthToken?
    ) {
        guard let token = tokenProvider() else {
            Task { @MainActor in
                state = .failed(.expiredToken)
            }
            return
        }

        Task {
            await MainActor.run {
                state = .loading(0.0)
            }

            do {
                // Recursively fetch all files (off main thread)
                let allEntries = try await fetchAllFilesRecursively(path: path, token: token)

                // Filter playable media files (audio + video)
                let mediaEntries = allEntries.filter { entry in
                    guard !entry.isDir else { return false }
                    let ext = (entry.serverFilename as NSString).pathExtension.lowercased()
                    return PlayableMediaFormat.isPlayableExtension(ext)
                }

                // Validate
                guard !mediaEntries.isEmpty else {
                    await MainActor.run {
                        state = .failed(.noAudioFound)
                    }
                    return
                }

                if mediaEntries.count > maxTracksPerCollection {
                    await MainActor.run {
                        state = .failed(.tooManyTracks(mediaEntries.count))
                    }
                    return
                }

                // Sort by path and filename
                let sortedEntries = mediaEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

                // Convert to tracks
                var tracks: [AudiobookTrack] = []
                for (index, entry) in sortedEntries.enumerated() {
                    // Extract chapter from parent folder name (if file is in a subfolder)
                    let chapter = extractChapter(from: entry.path, rootPath: path)
                    
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
                        mediaKind: PlayableMediaFormat.mediaKind(forFilename: entry.serverFilename),
                        chapter: chapter
                    )
                    tracks.append(track)
                }

                let descEntries = allEntries.filter { entry in
                    guard !entry.isDir else { return false }
                    let ext = (entry.serverFilename as NSString).pathExtension.lowercased()
                    return ext == "desc"
                }
                if !descEntries.isEmpty {
                    tracks = await applyDescriptionFiles(
                        to: tracks,
                        descEntries: descEntries,
                        token: token
                    )
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

                let draft = CollectionDraft(
                    title: defaultTitle,
                    folderPath: path,
                    tracks: tracks,
                    selectedTrackIds: Set(tracks.map(\.id)),          // ALL selected by default
                    nonPlayableFiles: nonPlayableFiles,
                    totalSize: totalSize,
                    coverSuggestion: coverSuggestion
                )

                await MainActor.run {
                    state = .ready(draft)
                }

            } catch let error as CollectionBuildError {
                await MainActor.run {
                    state = .failed(error)
                }
            } catch {
                if let netdiskError = error as? NetdiskError, case .expiredToken = netdiskError {
                    await MainActor.run {
                        state = .failed(.expiredToken)
                    }
                } else {
                    await MainActor.run {
                        state = .failed(.networkFailure(error))
                    }
                }
            }
        }
    }

    private func fetchAllFilesRecursively(
        path: String,
        token: BaiduOAuthToken,
        currentProgress: Double = 0.0
    ) async throws -> [BaiduNetdiskEntry] {
        var allEntries: [BaiduNetdiskEntry] = []
        var directoriesToExplore: [(path: String, depth: Int)] = [(path, 0)]
        let maxDepth = 10 // Prevent infinite recursion

        while !directoriesToExplore.isEmpty {
            let (currentPath, depth) = directoriesToExplore.removeFirst()

            guard depth < maxDepth else { continue }

            // Update progress
            let progress = min(0.9, currentProgress + Double(allEntries.count) / 1000.0)
            await MainActor.run {
                state = .loading(progress)
            }

            // Fetch current directory
            let entries = try await client.listAllFiles(in: currentPath, token: token)

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

        await MainActor.run {
            state = .loading(1.0)
        }

        return allEntries
    }

    private func applyDescriptionFiles(
        to tracks: [AudiobookTrack],
        descEntries: [BaiduNetdiskEntry],
        token: BaiduOAuthToken
    ) async -> [AudiobookTrack] {
        let descMap = Self.descEntriesByBaseName(from: descEntries)
        guard !descMap.isEmpty else { return tracks }

        var updatedTracks = tracks
        var descCache: [String: String] = [:]

        for index in updatedTracks.indices {
            let baseName = Self.normalizedBaseName(updatedTracks[index].filename)
            guard let candidates = descMap[baseName] else { continue }

            let trackPath: String?
            if case let .baidu(_, path) = updatedTracks[index].location {
                trackPath = path
            } else {
                trackPath = nil
            }

            guard let descEntry = Self.selectDescEntry(for: trackPath, from: candidates) else { continue }

            let descText: String
            if let cached = descCache[descEntry.path] {
                descText = cached
            } else {
                do {
                    descText = try await client.downloadTextFile(path: descEntry.path, token: token)
                    descCache[descEntry.path] = descText
                } catch {
                    continue
                }
            }

            let trimmed = descText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var track = updatedTracks[index]
            var metadata = track.metadata
            metadata["description"] = trimmed
            track.metadata = metadata
            updatedTracks[index] = track
        }

        return updatedTracks
    }

    private static func normalizedBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }

    private static func descEntriesByBaseName(
        from entries: [BaiduNetdiskEntry]
    ) -> [String: [BaiduNetdiskEntry]] {
        Dictionary(grouping: entries) { entry in
            normalizedBaseName(entry.serverFilename)
        }
    }

    private static func selectDescEntry(
        for trackPath: String?,
        from candidates: [BaiduNetdiskEntry]
    ) -> BaiduNetdiskEntry? {
        guard let trackPath else { return candidates.first }
        let trackDirectory = (trackPath as NSString).deletingLastPathComponent
        if let match = candidates.first(where: { ($0.path as NSString).deletingLastPathComponent == trackDirectory }) {
            return match
        }
        return candidates.first
    }
    
    /// Extracts the chapter name from a file path based on the root path.
    /// - Parameters:
    ///   - filePath: The full path of the file (e.g., "/Audiobooks/Chapter 1/section-a/audio.mp3")
    ///   - rootPath: The root path that was selected for import (e.g., "/Audiobooks")
    /// - Returns: The chapter name (e.g., "Chapter 1") if the file is in a subfolder, nil otherwise
    private func extractChapter(from filePath: String, rootPath: String) -> String? {
        // Normalize paths to handle trailing slashes
        let normalizedRoot = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedFilePath = filePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Remove root path from the file path to get the relative path
        var relativePath: String
        if normalizedRoot.isEmpty {
            relativePath = normalizedFilePath
        } else if normalizedFilePath.hasPrefix(normalizedRoot) {
            relativePath = String(normalizedFilePath.dropFirst(normalizedRoot.count))
            // Remove leading slash if present
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
        } else {
            // File is outside root path, use the immediate parent folder
            relativePath = (filePath as NSString).deletingLastPathComponent
        }
        
        // If no relative path or it's empty, file is directly under root
        guard !relativePath.isEmpty else { return nil }
        
        // Get the first component of the relative path (the immediate parent folder)
        let components = relativePath.components(separatedBy: "/")
        
        // If there's only one component, the file is directly under root (no subfolder)
        // e.g. relativePath = "011-23-xxxx.m4a" → no chapter
        guard components.count > 1,
              let firstComponent = components.first, !firstComponent.isEmpty else { return nil }
        
        return firstComponent
    }
}

// Extension to BaiduNetdiskClient
extension BaiduNetdiskClient {
    func listAllFiles(in path: String, token: BaiduOAuthToken) async throws -> [BaiduNetdiskEntry] {
        // For now, just return the first page
        // TODO: Implement pagination if needed
        return try await listDirectory(path: path, token: token)
    }
}

