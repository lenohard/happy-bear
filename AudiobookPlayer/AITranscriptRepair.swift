import Foundation
import OSLog

struct TranscriptRepairPromptBuilder {
    let trackTitle: String
    let collectionTitle: String?
    let collectionDescription: String?
    let instructions: String

    func makeUserPrompt(from selections: [TranscriptRepairSelection]) -> String {
        var lines: [String] = []
        lines.append("Track: \(trackTitle)")
        if let collectionTitle, !collectionTitle.isEmpty {
            lines.append("Collection: \(collectionTitle)")
        }
        if let collectionDescription, !collectionDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Collection description: \(collectionDescription)")
        }
        lines.append(instructions)
        lines.append("Segments")
        for selection in selections {
            let text = selection.segment.text.replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(selection.displayIndex)] \(text)")
        }
        return lines.joined(separator: "\n")
    }
}

struct TranscriptRepairResponse: Decodable {
    struct SegmentRepair: Decodable {
        let index: Int
        let editedText: String

        enum CodingKeys: String, CodingKey {
            case index
            case editedText = "edited_text"
        }
    }

    let repairs: [SegmentRepair]
}

enum TranscriptRepairParserError: Error {
    case emptyResponse
    case decodingFailed
    case invalidIndexes
}

struct TranscriptRepairParser {
    func parse(_ content: String) throws -> TranscriptRepairResponse {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptRepairParserError.emptyResponse
        }

        let data = Data(content.utf8)
        do {
            return try JSONDecoder().decode(TranscriptRepairResponse.self, from: data)
        } catch {
            throw TranscriptRepairParserError.decodingFailed
        }
    }
}

struct TranscriptRepairSelection {
    let displayIndex: Int
    let segment: TranscriptSegment
}

struct TranscriptRepairResult {
    let segmentId: String
    let originalText: String
    let repairedText: String
    let displayIndex: Int
}

enum AITranscriptRepairError: LocalizedError {
    case missingAPIKey
    case emptySelection
    case llmFailure(String)
    case responseParseFailed
    case unmatchedIndexes

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "AI key is missing"
        case .emptySelection:
            return "Select at least one segment to repair."
        case .llmFailure(let message):
            return "AI repair failed: \(message)"
        case .responseParseFailed:
            return "AI response could not be parsed."
        case .unmatchedIndexes:
            return "AI returned indexes that do not match the selected segments."
        }
    }
}

final class AITranscriptRepairManager {
    private let dbManager: GRDBDatabaseManager
    private let client: AIGatewayClient
    private let parser = TranscriptRepairParser()
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "AITranscriptRepair")

    private let systemPrompt = """
    You repair audiobook transcripts. Return JSON only: {"repairs":[{"index":NUMBER,"edited_text":"TEXT"}]}.
    Keep timestamps and segment counts unchanged. Fix spelling/grammar while preserving meaning, names, and punctuation style.
    Only return entries for lines that changed. Avoid adding or removing dialogue quotes unless the original was clearly wrong.
    """

    init(
        dbManager: GRDBDatabaseManager = .shared,
        client: AIGatewayClient = AIGatewayClient()
    ) {
        self.dbManager = dbManager
        self.client = client
    }

    func repairSegments(
        transcriptId: String,
        trackTitle: String,
        collectionTitle: String?,
        collectionDescription: String?,
        selections: [TranscriptRepairSelection],
        model: String,
        apiKey: String
    ) async throws -> [TranscriptRepairResult] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranscriptRepairError.missingAPIKey
        }

        guard !selections.isEmpty else {
            throw AITranscriptRepairError.emptySelection
        }

        let promptBuilder = TranscriptRepairPromptBuilder(
            trackTitle: trackTitle,
            collectionTitle: collectionTitle,
            collectionDescription: collectionDescription,
            instructions: "Clean the transcript text while keeping timestamps and speaker order untouched."
        )

        let userPrompt = promptBuilder.makeUserPrompt(from: selections)

        logger.info(
            "Sending AI transcript repair request (transcript: \(transcriptId, privacy: .public), model: \(model, privacy: .public), segments: \(selections.count))\nPrompt:\n\(userPrompt, privacy: .public)"
        )

        let response: ChatCompletionsResponse
        do {
            response = try await client.sendChat(
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 512,
                temperature: 0.2
            )
        } catch {
            throw AITranscriptRepairError.llmFailure(error.localizedDescription)
        }

        guard let content = response.choices.first?.message.content else {
            throw AITranscriptRepairError.responseParseFailed
        }

        logger.info(
            "Received AI transcript repair response (id: \(response.id, privacy: .public), model: \(response.model, privacy: .public))\nContent:\n\(content, privacy: .public)"
        )

        let parsed: TranscriptRepairResponse
        do {
            parsed = try parser.parse(content)
        } catch {
            throw AITranscriptRepairError.responseParseFailed
        }

        let indexMap = Dictionary(uniqueKeysWithValues: selections.map { ($0.displayIndex, $0.segment) })

        var updates: [String: String] = [:]
        var results: [TranscriptRepairResult] = []

        for repair in parsed.repairs {
            guard let segment = indexMap[repair.index] else {
                throw AITranscriptRepairError.unmatchedIndexes
            }
            let trimmed = repair.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != segment.text else { continue }
            updates[segment.id] = trimmed
            results.append(
                TranscriptRepairResult(
                    segmentId: segment.id,
                    originalText: segment.text,
                    repairedText: trimmed,
                    displayIndex: repair.index
                )
            )
        }

        guard !updates.isEmpty else {
            return []
        }

        try await dbManager.applyTranscriptRepairs(
            transcriptId: transcriptId,
            editedTextsBySegmentId: updates,
            model: response.model
        )

        return results
    }
}

#if DEBUG
enum TranscriptRepairParserTests {
    static func runSmokeTest() {
        let json = """
        {"repairs":[{"index":0,"edited_text":"Corrected text."}]}
        """
        let parser = TranscriptRepairParser()
        do {
            let response = try parser.parse(json)
            assert(response.repairs.count == 1)
            assert(response.repairs.first?.editedText == "Corrected text.")
        } catch {
            assertionFailure("TranscriptRepairParserTests failed: \(error)")
        }
    }
}
#endif
