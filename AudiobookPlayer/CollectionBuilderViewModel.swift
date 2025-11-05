import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum CollectionBuildError: LocalizedError {
    case noAudioFound
    case tooManyTracks(Int)
    case expiredToken
    case networkFailure(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .noAudioFound:
            return "No audio files found in this folder"
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
    var nonAudioFiles: [String]
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

@MainActor
final class CollectionBuilderViewModel: ObservableObject {
    enum State {
        case idle
        case loading(Double)
        case ready(CollectionDraft)
        case failed(CollectionBuildError)
    }

    @Published private(set) var state: State = .idle

    private let client: BaiduNetdiskClient
    private let maxTracksPerCollection = 500
    private let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "opus", "ogg"]

    init(client: BaiduNetdiskClient = BaiduNetdiskClient()) {
        self.client = client
    }

    func buildCollection(
        from path: String,
        title: String?,
        tokenProvider: @escaping () -> BaiduOAuthToken?
    ) async {
        guard let token = tokenProvider() else {
            state = .failed(.expiredToken)
            return
        }

        state = .loading(0.0)

        do {
            // Recursively fetch all files
            let allEntries = try await fetchAllFilesRecursively(path: path, token: token)

            // Filter audio files
            let audioEntries = allEntries.filter { entry in
                guard !entry.isDir else { return false }
                let ext = (entry.serverFilename as NSString).pathExtension.lowercased()
                return audioExtensions.contains(ext)
            }

            // Validate
            guard !audioEntries.isEmpty else {
                state = .failed(.noAudioFound)
                return
            }

            if audioEntries.count > maxTracksPerCollection {
                state = .failed(.tooManyTracks(audioEntries.count))
                return
            }

            // Sort by path and filename
            let sortedEntries = audioEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

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
                    metadata: [:]
                )
                tracks.append(track)
            }

            // Collect non-audio files for info
            let nonAudioFiles = allEntries
                .filter { !$0.isDir && !audioExtensions.contains(($0.serverFilename as NSString).pathExtension.lowercased()) }
                .map { $0.serverFilename }

            // Calculate total size
            let totalSize = audioEntries.reduce(0) { $0 + $1.size }

            // Generate default title
            let defaultTitle = title ?? (path as NSString).lastPathComponent

            // Generate cover suggestion (gradient based on title)
            let coverSuggestion = generateCoverGradient(for: defaultTitle)

            let draft = CollectionDraft(
                title: defaultTitle,
                folderPath: path,
                tracks: tracks,
                selectedTrackIds: Set(tracks.map(\.id)),          // ALL selected by default
                nonAudioFiles: nonAudioFiles,
                totalSize: totalSize,
                coverSuggestion: coverSuggestion
            )

            state = .ready(draft)

        } catch {
            if let netdiskError = error as? NetdiskError, case .expiredToken = netdiskError {
                state = .failed(.expiredToken)
            } else {
                state = .failed(.networkFailure(error))
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

    private func generateCoverGradient(for title: String) -> CollectionCover {
        // Generate color from title hash
        let hash = abs(title.hashValue)
        let hue = Double(hash % 360) / 360.0
        let color = Color(hue: hue, saturation: 0.6, brightness: 0.8)

        // Convert to hex
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))

        return CollectionCover(kind: .solid(colorHex: hex), dominantColorHex: hex)
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
