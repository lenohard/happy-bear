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
    /// When true, always include translated transcript lines in the `translations` array.
    /// When false, translations are only expected for songs/very short tracks.
    let requestTranslations: Bool
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

struct TrackSummaryTranslationPayload: Equatable {
    let orderIndex: Int
    let startTimeMs: Int
    let translation: String
}

struct TrackSummaryGenerationResult: Equatable {
    let summaryTitle: String?
    let summaryBody: String
    let keywords: [String]
    let mentionedItems: [String]
    let suggestedCorrections: [String: String]
    let sections: [TrackSummarySectionPayload]
    let translations: [TrackSummaryTranslationPayload]
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
        if context.requestTranslations {
            return makeTranslationOnlyPrompts(from: context)
        }

        let systemPrompt = """
        You are an audiobook editor. Produce accurate summaries and outlines of narrated recordings.
        The transcript may have some typos, try to fix them use the correct ones in your summary.
        Output strictly valid JSON using the schema provided. Keep sections chronological, non-overlapping,
        and representative of the actual transcript. Reuse the provided millisecond timestamps so the app can seek directly.
        Reply in the same language as the transcript.
        Use corrections in summary and sections.
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
        if let description = context.collectionDescription, !description.isEmpty {
            metadata.append("Collection description: \(description)")
        }


        let keywordInstruction = context.includeKeywords
            ? "Provide up to 5 concise keywords per section and globally."
            : "Return empty keyword arrays."

        let translationInstruction: String
        if context.requestTranslations {
            translationInstruction = """
            - You MUST include a `translations` array with entries aligned to the provided `start_ms` values, translating the transcript text into Chinese.
            - This is a mandatory requirement even if the track is long or an audiobook.
            - Don't return 'translate' field if original langauge is Chinese.
            """
        } else {
            translationInstruction = """
            - Only include `translations` when the track is a song or the transcript is under 5 minutes. For other cases, don't return 'translations' field.
            """
        }

        let excerpt = transcriptExcerpt(for: context.segments)

        let schema = """
        {
          "summary": {
            "suggested_corrections": {
              "incorrect spelling": "correct spelling"
            },
            "title": "optional short title",
            "overview": "Summarizing the overall track",
            "keywords": ["keyword1", "keyword2"],
            "mentioned_items": ["《Book Title》(Author)", "《Movie Name》(Director, year)"],
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
          ],
          "translations":[ // optional, include when 1. this is a song or short transcript under 5 minute. 2. when the instruction explictly ask for it.
          {
          "order":1,
          "start_ms": xx,
          "translation": "xxxxxxx",
          }
          ]
        }
        """

        let userPrompt = """
        You will receive ordered transcript segments with timestamps.
        

        Metadata:
        \(metadata.joined(separator: "\n"))

        Requirements:
        - Decide whether the transcript is primarily song lyrics or a regular narration.
        - If it is a song or short transcript (under 5 minutes):
          - Keep using this template but describe the song (title, performer, release background, etc.) in `summary.overview`, adding any notable context when the track is well known.
          - Don't include `sections` field. Beacuse the audio is short or song, sections are not needed.
        - If it is not a song, follow the normal audiobook summary workflow.

        Translation Requirements:
        \(translationInstruction)

        Other Requirements:
        - Provide a concise overview (2-3 sentences).
        - Sections must have `start_ms` integers derived from the provided `start_ms` values (do not invent new times).
        - Keep `end_ms` optional; omit if uncertain.
        - \(keywordInstruction)
        - Extract any books or movies mentioned in the transcript into `mentioned_items`. Format: "Title (Author/Director, Year)" if author/director and year are mentioned in the transcript; otherwise just "Title".
        - For correction, don't change the language, eg correct English into Chinese, you should correct within the same language.
        - Identify frequent obvious typos in important terms (movie titles, book titles, people names) that appear repeatedly in the transcript.
        - IMPORTANT: Only suggest corrections where the incorrect and correct spellings are DIFFERENT. Do NOT include entries where both sides are identical (e.g., "王家卫": "王家卫" is invalid).
        - Return `suggested_corrections` as a dictionary: keys are incorrect spellings found in the transcript, values are their correct spellings. For common errors with variations (e.g., '错误1', '错误2', '错误h'), consolidate them into a single canonical correction entry (e.g., '错误': '正确').
        - Only include important repeated errors that need fixing, not minor one-off typos.
        - Use the corrected spellings in your summary and section texts.
        - Output ONLY JSON, no prose, matching this schema exactly:
        - Always use Chinese for the result no matter what the input language is.

        \(schema)

        Transcript segments (format: [HH:MM:SS | start_ms=NNN] text):
        \(excerpt)
        """

        return TrackSummaryPrompts(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func makeTranslationOnlyPrompts(from context: TrackSummaryPromptContext) -> TrackSummaryPrompts {
        let systemPrompt = """
        You are a professional translator. Translate transcript segments into Chinese.
        Output strictly valid JSON using the schema provided. No prose.
        The JSON must remain compatible with the existing parser.
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

        let excerpt = translationExcerpt(for: context.segments)

        let schema = """
        {
          "summary": {
            "suggested_corrections": {},
            "title": "optional short title",
            "overview": "non-empty placeholder (required by parser)",
            "keywords": [],
            "mentioned_items": []
          },
          "sections": [],
          "translations": [
            [1, "translation text"]
          ]
        }
        """

        let userPrompt = """
        You will receive ordered transcript segments without timestamps.

        Metadata:
        \(metadata.joined(separator: "\n"))

        Requirements:
        - Translate EVERY transcript segment into Chinese.
        - Return one `translations` entry per input segment when possible; if a line is unclear, you may return an empty string.
        - Use the compact tuple format `[order, translation]` where `order` is a 1-based index matching the input line number.
        - Keep tuples compact; translation text may omit quotes to save tokens.
        - Do NOT include any timestamps or `start_ms` values.
        - Do NOT summarize. Leave `sections` as an empty array.
        - `summary.overview` MUST be non-empty, but should be a short fixed placeholder like "Translations only".
        - Set `summary.keywords` and `summary.mentioned_items` to empty arrays.
        - Set `summary.suggested_corrections` to an empty object.
        - Output ONLY a JSON-like object matching this schema as closely as possible:

        \(schema)

        Transcript segments (format: "1. text"):
        \(excerpt)
        """

        return TrackSummaryPrompts(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func parseResponse(_ raw: String) throws -> TrackSummaryGenerationResult {
        let payload = try decodeResponse(raw)
        let summaryFields = try parseSummaryFields(from: payload)

        let translations = payload.translations
            .compactMap { entry -> TrackSummaryTranslationPayload? in
                guard let startMs = entry.normalizedStartMs else { return nil }
                guard let text = entry.translation?.trimmedNonEmpty else { return nil }
                return TrackSummaryTranslationPayload(
                    orderIndex: entry.order ?? 0,
                    startTimeMs: max(0, startMs),
                    translation: text
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
                TrackSummaryTranslationPayload(
                    orderIndex: index,
                    startTimeMs: payload.startTimeMs,
                    translation: payload.translation
                )
            }

        return TrackSummaryGenerationResult(
            summaryTitle: summaryFields.summaryTitle,
            summaryBody: summaryFields.summaryBody,
            keywords: summaryFields.keywords,
            mentionedItems: summaryFields.mentionedItems,
            suggestedCorrections: summaryFields.suggestedCorrections,
            sections: summaryFields.sections,
            translations: translations
        )
    }

    func parseTranslationOnlyResponse(_ raw: String, segments: [TranscriptSegment]) throws -> TrackSummaryGenerationResult {
        let orderedSegments = segments.sorted { $0.startTimeMs < $1.startTimeMs }

        do {
            let payload = try decodeResponse(raw)
            let summaryFields = try parseSummaryFields(from: payload)
            let translations = normalizeTranslationOnlyEntries(payload.translations, orderedSegments: orderedSegments)

            return TrackSummaryGenerationResult(
                summaryTitle: summaryFields.summaryTitle,
                summaryBody: summaryFields.summaryBody,
                keywords: summaryFields.keywords,
                mentionedItems: summaryFields.mentionedItems,
                suggestedCorrections: summaryFields.suggestedCorrections,
                sections: summaryFields.sections,
                translations: translations
            )
        } catch {
            return parseTranslationOnlyResponseLenient(raw, orderedSegments: orderedSegments)
        }
    }

    private func normalizeTranslationOnlyEntries(
        _ entries: [TrackSummaryLLMResponse.Translation],
        orderedSegments: [TranscriptSegment]
    ) -> [TrackSummaryTranslationPayload] {
        var translations: [TrackSummaryTranslationPayload] = []
        translations.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let text = entry.translation ?? ""
            let orderValue = entry.order ?? (index + 1)
            let segmentIndex = orderValue - 1
            guard segmentIndex >= 0, segmentIndex < orderedSegments.count else {
                continue
            }
            let startMs = orderedSegments[segmentIndex].startTimeMs
            translations.append(
                TrackSummaryTranslationPayload(
                    orderIndex: segmentIndex,
                    startTimeMs: max(0, startMs),
                    translation: text
                )
            )
        }

        return normalizeTranslationOrder(translations)
    }

    private func normalizeTranslationOrder(_ translations: [TrackSummaryTranslationPayload]) -> [TrackSummaryTranslationPayload] {
        translations
            .sorted { lhs, rhs in
                if lhs.startTimeMs == rhs.startTimeMs {
                    return lhs.orderIndex < rhs.orderIndex
                }
                return lhs.startTimeMs < rhs.startTimeMs
            }
            .enumerated()
            .map { index, payload in
                TrackSummaryTranslationPayload(
                    orderIndex: index,
                    startTimeMs: payload.startTimeMs,
                    translation: payload.translation
                )
            }
    }

    private func parseTranslationOnlyResponseLenient(
        _ raw: String,
        orderedSegments: [TranscriptSegment]
    ) -> TrackSummaryGenerationResult {
        let translations = parseTranslationTuples(from: raw, orderedSegments: orderedSegments)

        return TrackSummaryGenerationResult(
            summaryTitle: nil,
            summaryBody: "Translations only",
            keywords: [],
            mentionedItems: [],
            suggestedCorrections: [:],
            sections: [],
            translations: normalizeTranslationOrder(translations)
        )
    }

    private func parseTranslationTuples(
        from raw: String,
        orderedSegments: [TranscriptSegment]
    ) -> [TrackSummaryTranslationPayload] {
        let pattern = #"\[\s*(\d+)\s*,\s*(?:"((?:[^"\\]|\\.)*)"|([^\]]+))\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, options: [], range: range)

        var translations: [TrackSummaryTranslationPayload] = []
        translations.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges >= 4,
                  let orderRange = Range(match.range(at: 1), in: raw),
                  let quotedRange = Range(match.range(at: 2), in: raw) ?? Range(match.range(at: 3), in: raw) else {
                continue
            }
            let orderText = String(raw[orderRange])
            guard let orderValue = Int(orderText) else { continue }
            let segmentIndex = orderValue - 1
            guard segmentIndex >= 0, segmentIndex < orderedSegments.count else {
                continue
            }

            let rawText = String(raw[quotedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let unquotedText = rawText.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let decodedText = decodeJSONString(unquotedText) ?? unquotedText
            let startMs = orderedSegments[segmentIndex].startTimeMs
            translations.append(
                TrackSummaryTranslationPayload(
                    orderIndex: segmentIndex,
                    startTimeMs: max(0, startMs),
                    translation: decodedText
                )
            )
        }

        return translations
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

    func translationExcerpt(for segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "No transcript available." }

        return segments
            .sorted(by: { $0.startTimeMs < $1.startTimeMs })
            .enumerated()
            .compactMap { index, segment -> String? in
                let sanitized = segment.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !sanitized.isEmpty else { return nil }

                return "\(index + 1). \(sanitized)"
            }
            .joined(separator: "\n")
    }

    func decodeResponse(_ raw: String) throws -> TrackSummaryLLMResponse {
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
            return try decoder.decode(TrackSummaryLLMResponse.self, from: data)
        } catch {
            throw TrackSummaryGenerationError.decodingFailed(error.localizedDescription)
        }
    }

    func parseSummaryFields(from payload: TrackSummaryLLMResponse) throws -> (
        summaryTitle: String?,
        summaryBody: String,
        keywords: [String],
        mentionedItems: [String],
        suggestedCorrections: [String: String],
        sections: [TrackSummarySectionPayload]
    ) {
        guard let overview = payload.summary.overview?.trimmedNonEmpty else {
            throw TrackSummaryGenerationError.missingSummaryBody
        }

        let keywords = payload.summary.keywords ?? []
        let mentionedItems = payload.summary.mentionedItems ?? []
        let suggestedCorrections = payload.summary.suggestedCorrections ?? [:]
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

        return (
            summaryTitle: payload.summary.title?.trimmedNonEmpty,
            summaryBody: overview,
            keywords: keywords,
            mentionedItems: mentionedItems,
            suggestedCorrections: suggestedCorrections,
            sections: sections
        )
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

    func decodeJSONString(_ text: String) -> String? {
        let wrapped = "\"\(text)\""
        guard let data = wrapped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let string = object as? String else {
            return nil
        }
        return string
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
        let mentionedItems: [String]?
        let suggestedCorrections: [String: String]?

        enum CodingKeys: String, CodingKey {
            case title
            case overview
            case keywords
            case mentionedItems = "mentioned_items"
            case suggestedCorrections = "suggested_corrections"
        }
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

    struct Translation: Decodable {
        let order: Int?
        let startMs: Int?
        let startTimeMs: Int?
        let startSeconds: Double?
        let startTime: String?
        let translation: String?

        enum CodingKeys: String, CodingKey {
            case order
            case startMs = "start_ms"
            case startTimeMs = "start_time_ms"
            case startSeconds = "start_seconds"
            case startTime = "start_time"
            case translation
        }

        init(from decoder: Decoder) throws {
            if var container = try? decoder.unkeyedContainer() {
                order = try? container.decode(Int.self)
                translation = try? container.decode(String.self)
                startMs = nil
                startTimeMs = nil
                startSeconds = nil
                startTime = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = try container.decodeIfPresent(Int.self, forKey: .order)
            startMs = try container.decodeIfPresent(Int.self, forKey: .startMs)
            startTimeMs = try container.decodeIfPresent(Int.self, forKey: .startTimeMs)
            startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds)
            startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
            translation = try container.decodeIfPresent(String.self, forKey: .translation)
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
    }

    let summary: SummarySection
    let sections: [Section]
    let translations: [Translation]

    enum CodingKeys: String, CodingKey {
        case summary
        case sections
        case translations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(SummarySection.self, forKey: .summary)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
        translations = try container.decodeIfPresent([Translation].self, forKey: .translations) ?? []
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
