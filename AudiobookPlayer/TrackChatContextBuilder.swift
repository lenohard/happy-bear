import Foundation

struct TrackChatContextResult {
    let text: String
    let transcriptAvailable: Bool
    let transcriptTruncated: Bool
}

struct TrackChatContextBuilder {
    static let defaultMaxCharacters = 12000

    static func buildContext(
        track: AudiobookTrack?,
        collection: AudiobookCollection?,
        transcriptSegments: [TranscriptSegment],
        selection: TrackChatContextSelection,
        maxCharacters: Int = defaultMaxCharacters
    ) -> TrackChatContextResult {
        var sections: [String] = []

        if selection.includeTrackInfo {
            sections.append(formatTrackInfo(track))
        }

        if selection.includeCollectionInfo {
            sections.append(formatCollectionInfo(collection))
        }

        var transcriptTruncated = false
        var transcriptAvailable = !transcriptSegments.isEmpty

        if selection.includeTranscript {
            if transcriptSegments.isEmpty {
                transcriptAvailable = false
                sections.append("Transcript:\nNot available.")
            } else {
                let transcriptText = formatTranscript(
                    segments: transcriptSegments,
                    selection: selection,
                    maxCharacters: maxCharacters,
                    truncated: &transcriptTruncated
                )
                sections.append("Transcript:\n\(transcriptText)")
            }
        }

        let text = sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return TrackChatContextResult(
            text: text,
            transcriptAvailable: transcriptAvailable,
            transcriptTruncated: transcriptTruncated
        )
    }

    private static func formatTrackInfo(_ track: AudiobookTrack?) -> String {
        guard let track else { return "Track:\nUnavailable." }
        var lines: [String] = []
        lines.append("Title: \(track.displayName)")
        lines.append("Track #: \(track.trackNumber)")
        if let duration = track.duration {
            lines.append("Duration: \(formatDuration(duration))")
        }
        if !track.filename.isEmpty {
            lines.append("Filename: \(track.filename)")
        }
        if !track.metadata.isEmpty {
            let meta = track.metadata
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            lines.append("Metadata: \(meta)")
        }
        return "Track:\n" + lines.joined(separator: "\n")
    }

    private static func formatCollectionInfo(_ collection: AudiobookCollection?) -> String {
        guard let collection else { return "Collection:\nUnavailable." }
        var lines: [String] = []
        lines.append("Title: \(collection.title)")
        if let author = collection.author, !author.isEmpty {
            lines.append("Author: \(author)")
        }
        if let description = collection.description, !description.isEmpty {
            lines.append("Description: \(description)")
        }
        if !collection.tags.isEmpty {
            lines.append("Tags: \(collection.tags.joined(separator: ", "))")
        }
        return "Collection:\n" + lines.joined(separator: "\n")
    }

    private static func formatTranscript(
        segments: [TranscriptSegment],
        selection: TrackChatContextSelection,
        maxCharacters: Int,
        truncated: inout Bool
    ) -> String {
        let filteredSegments: [TranscriptSegment]
        switch selection.transcriptScope {
        case .full:
            filteredSegments = segments
        case .recent:
            let recentMinutes = max(1, selection.recentMinutes ?? 10)
            let cutoffMs = max(0, (segments.last?.endTimeMs ?? segments.last?.startTimeMs ?? 0) - recentMinutes * 60 * 1000)
            filteredSegments = segments.filter { $0.startTimeMs >= cutoffMs }
        case .auto:
            filteredSegments = segments
        }

        var lines: [String] = []
        var currentCount = 0

        for segment in filteredSegments {
            let timecode = timecode(for: segment.startTimeMs)
            let line = "[\(timecode)] \(segment.text)"
            if selection.transcriptScope == .auto {
                if currentCount + line.count > maxCharacters {
                    truncated = true
                    break
                }
            }
            lines.append(line)
            currentCount += line.count + 1
        }

        return lines.joined(separator: "\n")
    }

    private static func timecode(for ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, totalSeconds % 60)
    }
}
