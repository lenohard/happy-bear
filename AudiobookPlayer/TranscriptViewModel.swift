import Foundation
import SwiftUI

// MARK: - Transcript View Model

/// Manages state for transcript viewing and searching
@MainActor
class TranscriptViewModel: NSObject, ObservableObject {
    @Published var transcript: Transcript?
    @Published var segments: [TranscriptSegment] = []
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let trackId: String
    private let dbManager: GRDBDatabaseManager

    // MARK: - Computed Properties

    /// Segments matching the current search query
    var filteredSegments: [TranscriptSegment] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return segments
        }
        let query = searchText.lowercased()
        return segments.filter { $0.text.lowercased().contains(query) }
    }

    /// Full text of filtered segments for display
    var displayText: String {
        if filteredSegments.isEmpty {
            return transcript?.fullText ?? ""
        }
        return filteredSegments.map { $0.text }.joined(separator: " ")
    }

    /// Search results with context (segment index, match count)
    var searchResults: [TranscriptSearchResult] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        let query = searchText.lowercased()
        var results: [TranscriptSearchResult] = []

        for (index, segment) in segments.enumerated() {
            let lowerText = segment.text.lowercased()
            if lowerText.contains(query) {
                // Count occurrences in this segment
                let occurrences = lowerText.components(separatedBy: query).count - 1
                results.append(TranscriptSearchResult(
                    segmentIndex: index,
                    segment: segment,
                    matchCount: max(1, occurrences),
                    matchedText: nil
                ))
            }
        }

        return results
    }

    // MARK: - Initialization

    init(trackId: String, dbManager: GRDBDatabaseManager = .shared) {
        self.trackId = trackId
        self.dbManager = dbManager
        super.init()
    }

    // MARK: - Public API

    /// Load transcript and segments for the given track
    @MainActor
    func loadTranscript() async {
        print("[TranscriptViewModel] Starting to load transcript for track: \(trackId)")
        isLoading = true
        errorMessage = nil

        do {
            print("[TranscriptViewModel] Calling dbManager.loadTranscript...")

            // Load transcript (actor method with await)
            if let loadedTranscript = try await dbManager.loadTranscript(forTrackId: trackId) {
                print("[TranscriptViewModel] Loaded transcript: \(loadedTranscript.id)")
                self.transcript = loadedTranscript

                // Load segments
                print("[TranscriptViewModel] Loading segments for transcript: \(loadedTranscript.id)")
                let loadedSegments = try await dbManager.loadTranscriptSegments(forTranscriptId: loadedTranscript.id)

                print("[TranscriptViewModel] Loaded \(loadedSegments.count) segments")
                self.segments = loadedSegments

                if loadedSegments.isEmpty {
                    print("[TranscriptViewModel] WARNING: Transcript has 0 segments!")
                }
            } else {
                print("[TranscriptViewModel] No transcript found for track: \(trackId)")
                errorMessage = "Transcript not found"
                self.segments = []
            }
        } catch {
            print("[TranscriptViewModel] ERROR loading transcript: \(error)")
            errorMessage = "Failed to load transcript: \(error.localizedDescription)"
            self.segments = []
        }

        print("[TranscriptViewModel] Load complete. segments.count = \(segments.count)")
        isLoading = false
    }

    /// Get the playback position (in seconds) for a segment
    func getPlaybackPosition(for segment: TranscriptSegment) -> TimeInterval {
        return TimeInterval(segment.startTimeMs) / 1000.0
    }

    /// Get segment at specific playback time
    func getSegmentAtTime(_ timeSeconds: Double) -> TranscriptSegment? {
        let timeMs = Int(timeSeconds * 1000)
        return segments.first { $0.startTimeMs <= timeMs && timeMs <= $0.endTimeMs }
    }

    /// Highlight matching text in a segment
    func highlightedSegmentText(_ segment: TranscriptSegment) -> NSAttributedString {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = segment.text
        let attributedString = NSMutableAttributedString(string: text)

        guard !normalizedQuery.isEmpty else {
            return attributedString
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                  of: normalizedQuery,
                  options: [.caseInsensitive],
                  range: searchStart..<text.endIndex
              ) {
            let nsRange = NSRange(range, in: text)
            attributedString.addAttribute(
                .backgroundColor,
                value: UIColor.yellow.withAlphaComponent(0.3),
                range: nsRange
            )
            attributedString.addAttribute(
                .font,
                value: UIFont.systemFont(ofSize: 16, weight: .semibold),
                range: nsRange
            )
            searchStart = range.upperBound
        }

        return attributedString
    }

    /// Clear search
    func clearSearch() {
        searchText = ""
    }

    /// Get formatted time string
    static func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
