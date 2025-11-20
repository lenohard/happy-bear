import Foundation

// MARK: - Prompt Context

struct TrackSummaryPromptContext {
    let trackTitle: String
    let trackDuration: TimeInterval?
    let trackAuthor: String?
    let collectionTitle: String?
    let collectionDescription: String?
    let transcriptLanguage: String
    let segments: [TranscriptSegment]
    let targetSectionCount: Int?
    let includeKeywords: Bool
}

struct TrackSummaryPrompts {
    let systemPrompt: String
    let userPrompt: String
}

struct TrackSummarySectionPayload: Equatable {
    let orderIndex: Int
    let startTimeMs: Int
    let endTimeMs: Int?
    let title: String?
    let summary: String
    let keywords: [String]
}

struct TrackSummaryGenerationResult: Equatable {
    let summaryTitle: String?
    let summaryBody: String
    let keywords: [String]
    let sections: [TrackSummarySectionPayload]
}

enum TrackSummaryGenerationError: LocalizedError {
    case invalidJSONEnvelope
    case emptyResponse
    case decodingFailed(String)
    case missingSummaryBody

    var errorDescription: String? {
        switch self {
        case .invalidJSONEnvelope:
            return "Track summary response was not valid JSON."
        case .emptyResponse:
            return "The AI did not return any summary content."
        case .decodingFailed(let reason):
            return "Could not parse summary response: \(reason)"
        case .missingSummaryBody:
            return "Summary body missing. Ask the model to try again."
        }
    }
}

// MARK: - Generator

final class TrackSummaryGenerator {

    func makePrompts(from context: TrackSummaryPromptContext) -> TrackSummaryPrompts {
        let systemPrompt = """
        You are an audiobook editor. Produce accurate summaries and outlines of narrated recordings.
        Output strictly valid JSON using the schema provided. Keep sections chronological, non-overlapping,
        and representative of the actual transcript. Reuse the provided millisecond timestamps so the app can seek directly.
        """

        var metadata: [String] = []
        metadata.append("Track title: \(context.trackTitle)")

        if let author = context.trackAuthor, !author.isEmpty {
            metadata.append("Author/Narrator: \(author)")
        }
        if let collection = context.collectionTitle {
            metadata.append("Collection: \(collection)")
        }
        if let duration = context.trackDuration {
            metadata.append("Duration: \(Self.formatDuration(duration))")
        }
        metadata.append("Transcript language: \(context.transcriptLanguage)")
        if let description = context.collectionDescription, !description.isEmpty {
            metadata.append("Collection description: \(description)")
        }

        var sectionInstruction = "Aim for natural sections of 3–6 minutes each."
        if let target = context.targetSectionCount {
            sectionInstruction = "Produce about \(target) evenly sized sections."
        }

        let keywordInstruction = context.includeKeywords
            ? "Provide up to 5 concise keywords per section and globally."
            : "Return empty keyword arrays."

        let excerpt = transcriptExcerpt(for: context.segments)

        let schema = """
        {
          "summary": {
            "title": "optional short title",
            "overview": "2-3 sentences summarizing the overall track",
            "keywords": ["keyword1", "keyword2"]
          },
          "sections": [
            {
              "order": 1,
              "start_ms": 0,
              "end_ms": 180000,
              "title": "optional section title",
              "summary": "1-2 sentence blurb of the section",
              "keywords": ["topic", "theme"]
            }
          ]
        }
        """

        let userPrompt = """
        You will receive ordered transcript segments with timestamps.

        Metadata:
        \(metadata.joined(separator: "\n"))

        Requirements:
        - Provide a concise overview (2-3 sentences).
        - \(sectionInstruction)
        - Sections must have `start_ms` integers derived from the provided `start_ms` values (do not invent new times).
        - Keep `end_ms` optional; omit if uncertain.
        - \(keywordInstruction)
        - Output ONLY JSON, no prose, matching this schema exactly:
        \(schema)

        Transcript segments (format: [HH:MM:SS | start_ms=NNN] text):
        \(excerpt)
        """

        return TrackSummaryPrompts(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func parseResponse(_ raw: String) throws -> TrackSummaryGenerationResult {
        let cleaned = cleanedJSON(from: raw)
        guard !cleaned.isEmpty else {
            throw TrackSummaryGenerationError.emptyResponse
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw TrackSummaryGenerationError.invalidJSONEnvelope
        }

        do {
            let decoder = JSONDecoder()
            // Keys already map via CodingKeys; enabling convertFromSnakeCase here
            // caused nested values like `start_ms` to be skipped entirely.
            let payload = try decoder.decode(TrackSummaryLLMResponse.self, from: data)
            guard let overview = payload.summary.overview?.trimmedNonEmpty else {
                throw TrackSummaryGenerationError.missingSummaryBody
            }

            let keywords = payload.summary.keywords ?? []
            let sections = payload.sections
                .compactMap { section -> TrackSummarySectionPayload? in
                    guard let startMs = section.normalizedStartMs else { return nil }
                    guard let blurb = section.summary?.trimmedNonEmpty else { return nil }
                    let title = section.title?.trimmedNonEmpty
                    let keywords = section.keywords ?? []
                    let endMs = section.normalizedEndMs
                    return TrackSummarySectionPayload(
                        orderIndex: section.order ?? 0,
                        startTimeMs: max(0, startMs),
                        endTimeMs: endMs,
                        title: title,
                        summary: blurb,
                        keywords: keywords.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.startTimeMs == rhs.startTimeMs {
                        return lhs.orderIndex < rhs.orderIndex
                    }
                    return lhs.startTimeMs < rhs.startTimeMs
                }
                .enumerated()
                .map { index, payload in
                    TrackSummarySectionPayload(
                        orderIndex: index,
                        startTimeMs: payload.startTimeMs,
                        endTimeMs: payload.endTimeMs,
                        title: payload.title,
                        summary: payload.summary,
                        keywords: payload.keywords
                    )
                }

            return TrackSummaryGenerationResult(
                summaryTitle: payload.summary.title?.trimmedNonEmpty,
                summaryBody: overview,
                keywords: keywords,
                sections: sections
            )
        } catch {
            throw TrackSummaryGenerationError.decodingFailed(error.localizedDescription)
        }
    }
}

// MARK: - Helpers

private extension TrackSummaryGenerator {
    func transcriptExcerpt(for segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "No transcript available." }

        return segments
            .sorted(by: { $0.startTimeMs < $1.startTimeMs })
            .compactMap { segment -> String? in
                let sanitized = segment.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !sanitized.isEmpty else { return nil }

                let label = Self.timecode(for: segment.startTimeMs)
                return "[\(label) | start_ms=\(segment.startTimeMs)] \(sanitized)"
            }
            .joined(separator: "\n")
    }

    func cleanedJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("```") {
            if let startRange = trimmed.range(of: "```json") ?? trimmed.range(of: "```JSON") ?? trimmed.range(of: "```") {
                let afterFence = trimmed[startRange.upperBound...]
                if let closing = afterFence.range(of: "```") {
                    let inner = afterFence[..<closing.lowerBound]
                    return extractJSON(from: String(inner))
                }
            }
        }

        return extractJSON(from: trimmed)
    }

    func extractJSON(from text: String) -> String {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[firstBrace...lastBrace])
    }

    static func timecode(for ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, totalSeconds % 60)
    }
}

// MARK: - Decoding Payloads

private struct TrackSummaryLLMResponse: Decodable {
    struct SummarySection: Decodable {
        let title: String?
        let overview: String?
        let keywords: [String]?
    }

    struct Section: Decodable {
        let order: Int?
        let startMs: Int?
        let startTimeMs: Int?
        let startSeconds: Double?
        let startTime: String?
        let endMs: Int?
        let endTimeMs: Int?
        let endSeconds: Double?
        let endTime: String?
        let title: String?
        let summary: String?
        let keywords: [String]?

        enum CodingKeys: String, CodingKey {
            case order
            case startMs = "start_ms"
            case startTimeMs = "start_time_ms"
            case startSeconds = "start_seconds"
            case startTime = "start_time"
            case endMs = "end_ms"
            case endTimeMs = "end_time_ms"
            case endSeconds = "end_seconds"
            case endTime = "end_time"
            case title
            case summary
            case keywords
        }

        var normalizedStartMs: Int? {
            if let startMs { return startMs }
            if let startTimeMs { return startTimeMs }
            if let startSeconds {
                return Int(startSeconds * 1000)
            }
            if let startTime {
                return TrackSummaryGenerator.parseTimecode(startTime)
            }
            return nil
        }

        var normalizedEndMs: Int? {
            if let endMs { return endMs }
            if let endTimeMs { return endTimeMs }
            if let endSeconds {
                return Int(endSeconds * 1000)
            }
            if let endTime {
                return TrackSummaryGenerator.parseTimecode(endTime)
            }
            return nil
        }

        var sanitizedSummary: String? {
            summary?.trimmedNonEmpty
        }
    }

    let summary: SummarySection
    let sections: [Section]

    enum CodingKeys: String, CodingKey {
        case summary
        case sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(SummarySection.self, forKey: .summary)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }
}

private extension TrackSummaryGenerator {
    static func parseTimecode(_ text: String) -> Int? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "seconds", with: "")
            .replacingOccurrences(of: "s", with: "")
        if trimmed.contains(":") {
            let pieces = trimmed.split(separator: ":")
            guard !pieces.isEmpty else { return nil }
            var multiplier = 1.0
            var totalSeconds = 0.0
            for piece in pieces.reversed() {
                let cleaned = piece.replacingOccurrences(of: ",", with: ".")
                guard let value = Double(cleaned) else { return nil }
                totalSeconds += value * multiplier
                multiplier *= 60
            }
            return Int(totalSeconds * 1000)
        } else {
            let cleaned = trimmed.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(cleaned) else { return nil }
            return Int(value * 1000)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
