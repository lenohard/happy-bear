import Foundation
import SwiftUI

/// Manages state for transcript viewing and searching.
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
    func loadTranscript() async {
        isLoading = true
        errorMessage = nil

        do {
            // Ensure the GRDB database is ready before attempting to query transcripts.
            try await dbManager.initializeDatabase()

            // Load transcript (actor method with await)
            if let loadedTranscript = try await dbManager.loadTranscript(forTrackId: trackId) {
                self.transcript = loadedTranscript

                // Load segments
                let loadedSegments = try await dbManager.loadTranscriptSegments(forTranscriptId: loadedTranscript.id)

                self.segments = loadedSegments

            } else {
                errorMessage = "Transcript not found"
                self.segments = []
            }
        } catch {
            errorMessage = "Failed to load transcript: \(error.localizedDescription)"
            self.segments = []
        }

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

    /// Finds the closest segment for a playback time, even if the exact time is between segments.
    func segmentClosest(to timeSeconds: Double) -> TranscriptSegment? {
        guard !segments.isEmpty else { return nil }

        if let exact = getSegmentAtTime(timeSeconds) {
            return exact
        }

        let timeMs = Int(timeSeconds * 1000)

        if let next = segments.first(where: { $0.startTimeMs > timeMs }) {
            return next
        }

        return segments.last
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
