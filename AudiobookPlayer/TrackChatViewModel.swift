import Foundation
import OSLog

@MainActor
final class TrackChatViewModel: ObservableObject {
    @Published private(set) var sessions: [TrackChatSession] = []
    @Published private(set) var selectedSession: TrackChatSession?
    @Published private(set) var messages: [TrackChatMessage] = []
    @Published var draftMessage: String = ""
    @Published var isSending = false
    @Published var errorMessage: String? {
        didSet {
            // Auto-clear error after 5 seconds
            if errorMessage != nil {
                errorClearTask?.cancel()
                errorClearTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.errorMessage = nil
                }
            }
        }
    }
    @Published var contextSelection: TrackChatContextSelection = .default(transcriptAvailable: true)
    @Published var contextPreview: String = ""
    @Published var transcriptWarning: String?
    @Published var transcriptTruncated = false

    private let trackId: String
    private let collectionId: String?
    private let dbManager: GRDBDatabaseManager
    private let client: AIGatewayClient
    private let keyStore: AIGatewayAPIKeyStore
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "TrackChat")
    private var errorClearTask: Task<Void, Never>?
    private var streamingUpdateTask: Task<Void, Never>?
    private var pendingStreamText: String = ""
    private var pendingStreamReasoning: String = ""
    private var reasoningStartTime: Date?
    private var reasoningEndTime: Date?
    private let streamingThrottleInterval: UInt64 = 50_000_000 // 50ms

    init(
        trackId: String,
        collectionId: String?,
        dbManager: GRDBDatabaseManager = .shared,
        client: AIGatewayClient = AIGatewayClient(),
        keyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore()
    ) {
        self.trackId = trackId
        self.collectionId = collectionId
        self.dbManager = dbManager
        self.client = client
        self.keyStore = keyStore
    }

    func load(track: AudiobookTrack?, collection: AudiobookCollection?) async {
        do {
            try await dbManager.initializeDatabase()
            let fetchedSessions = try await dbManager.fetchTrackChatSessions(trackId: trackId)
            sessions = fetchedSessions

            if let latest = fetchedSessions.first {
                await selectSession(latest, track: track, collection: collection)
            } else {
                let defaults = try await dbManager.fetchTrackChatDefaults(trackId: trackId)
                let hasTranscript = await trackHasTranscript()
                contextSelection = defaults ?? TrackChatContextSelection.default(transcriptAvailable: hasTranscript)
                let newSession = try await dbManager.createTrackChatSession(
                    trackId: trackId,
                    collectionId: collectionId,
                    modelId: nil,
                    title: defaultSessionTitle(),
                    contextSelection: contextSelection,
                    contextSnapshot: nil
                )
                sessions = [newSession]
                await selectSession(newSession, track: track, collection: collection)
            }
        } catch {
            logger.error("Failed to load track chat sessions: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func startNewSession(track: AudiobookTrack?, collection: AudiobookCollection?, modelId: String?) async {
        do {
            let selection = try await dbManager.fetchTrackChatDefaults(trackId: trackId)
                ?? contextSelection
            let newSession = try await dbManager.createTrackChatSession(
                trackId: trackId,
                collectionId: collectionId,
                modelId: modelId,
                title: defaultSessionTitle(),
                contextSelection: selection,
                contextSnapshot: nil
            )
            sessions.insert(newSession, at: 0)
            await selectSession(newSession, track: track, collection: collection)
        } catch {
            logger.error("Failed to create new session: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ session: TrackChatSession, track: AudiobookTrack?, collection: AudiobookCollection?) async {
        selectedSession = session
        contextSelection = session.contextSelection
        do {
            let loadedMessages = try await dbManager.fetchTrackChatMessages(sessionId: session.id)
            messages = loadedMessages
        } catch {
            logger.error("Failed loading messages: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        await refreshContextPreview(track: track, collection: collection)
    }

    func refreshContextPreview(track: AudiobookTrack?, collection: AudiobookCollection?) async {
        do {
            try await dbManager.initializeDatabase()
            let transcriptResult = try await loadTranscriptSegments()
            let result = TrackChatContextBuilder.buildContext(
                track: track,
                collection: collection,
                transcriptSegments: transcriptResult,
                selection: contextSelection
            )
            contextPreview = result.text
            transcriptTruncated = contextSelection.includeTranscript && result.transcriptTruncated
            transcriptWarning = contextSelection.includeTranscript && !result.transcriptAvailable
                ? NSLocalizedString("track_chat_transcript_unavailable", comment: "Transcript not available")
                : nil
        } catch {
            contextPreview = ""
            transcriptTruncated = false
            transcriptWarning = error.localizedDescription
        }
    }

    func applyContextSelection(_ selection: TrackChatContextSelection, track: AudiobookTrack?, collection: AudiobookCollection?) async {
        contextSelection = selection
        if let sessionId = selectedSession?.id {
            do {
                try await dbManager.updateTrackChatSession(
                    sessionId: sessionId,
                    modelId: nil,
                    contextSelection: selection,
                    contextSnapshot: nil
                )
                try await dbManager.saveTrackChatDefaults(trackId: trackId, selection: selection)
                updateSessionLocalState(sessionId: sessionId, contextSelection: selection, modelId: nil)
            } catch {
                logger.error("Failed updating context selection: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        await refreshContextPreview(track: track, collection: collection)
    }

    func sendMessage(
        prompt: String,
        modelId: String,
        track: AudiobookTrack?,
        collection: AudiobookCollection?
    ) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        guard let session = selectedSession else { return }
        let storedKey = try? keyStore.loadKey()
        guard let apiKey = storedKey ?? nil, !apiKey.isEmpty else {
            errorMessage = NSLocalizedString("ai_tab_missing_key", comment: "")
            return
        }

        errorMessage = nil
        isSending = true

        await refreshContextPreview(track: track, collection: collection)
        let contextSnapshot = contextPreview
        do {
            try await dbManager.updateTrackChatSession(
                sessionId: session.id,
                modelId: modelId,
                contextSelection: contextSelection,
                contextSnapshot: contextSnapshot
            )
            updateSessionLocalState(sessionId: session.id, contextSelection: contextSelection, modelId: modelId)
        } catch {
            logger.error("Failed saving context snapshot: \(error.localizedDescription, privacy: .public)")
        }

        let userMessage = TrackChatMessage(
            sessionId: session.id,
            role: .user,
            content: trimmedPrompt
        )

        // Persist user message BEFORE adding to UI to avoid race condition
        do {
            try await dbManager.insertTrackChatMessage(userMessage)
            try await dbManager.touchTrackChatSession(sessionId: session.id)
            // Only add to UI after successful persistence
            messages.append(userMessage)
            draftMessage = ""
        } catch {
            logger.error("Failed saving user message: \(error.localizedDescription, privacy: .public)")
            errorMessage = NSLocalizedString("track_chat_save_failed", comment: "Failed to save message")
            isSending = false
            return
        }

        let assistantId = UUID().uuidString
        var assistantMessage = TrackChatMessage(
            id: assistantId,
            sessionId: session.id,
            role: .assistant,
            content: ""
        )
        messages.append(assistantMessage)

        // Construct conversation history
        var apiMessages: [[String: Any]] = []

        // 1. System Prompt with Context
        let systemPromptContent = """
        You are a helpful assistant for audiobook listeners. Use the provided context to answer questions about the current track.

        Context:
        \(contextSnapshot)
        """
        apiMessages.append(["role": "system", "content": systemPromptContent])

        // 2. History (excluding the just-added user message and the placeholder assistant message)
        let historyMessages = messages.dropLast(2)
        for msg in historyMessages {
            apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        // 3. Current User Message
        apiMessages.append(["role": "user", "content": trimmedPrompt])

        do {
            pendingStreamText = ""
            pendingStreamReasoning = ""
            reasoningStartTime = nil
            reasoningEndTime = nil
            let response = try await client.sendChatMessages(
                apiKey: apiKey,
                model: modelId,
                messages: apiMessages,
                temperature: 0.3,
                reasoning: nil,
                onStreamDelta: { [weak self] delta in
                    guard let self else { return }
                    switch delta {
                    case .content(let content):
                        // Mark end of reasoning when content starts
                        if self.reasoningStartTime != nil && self.reasoningEndTime == nil {
                            self.reasoningEndTime = Date()
                        }
                        self.pendingStreamText.append(content)
                    case .reasoning(let reasoning):
                        // Mark start of reasoning on first reasoning delta
                        if self.reasoningStartTime == nil {
                            self.reasoningStartTime = Date()
                        }
                        self.pendingStreamReasoning.append(reasoning)
                    }
                    // Throttle UI updates to reduce main thread pressure
                    self.scheduleStreamingUpdate(assistantId: assistantId)
                }
            )

            // Cancel any pending throttled update
            streamingUpdateTask?.cancel()
            streamingUpdateTask = nil

            let finalText = response.choices.first?.message.content ?? pendingStreamText

            // Extract reasoning from either direct reasoning field or reasoningDetails
            var finalReasoning = response.choices.first?.message.reasoning ?? pendingStreamReasoning
            if finalReasoning.isEmpty, let details = response.choices.first?.message.reasoningDetails {
                // Extract text from reasoning details (OpenAI o1, Claude extended thinking format)
                let detailTexts = details.compactMap { detail -> String? in
                    if let text = detail.text, !text.isEmpty {
                        return text
                    }
                    if let summary = detail.summary, !summary.isEmpty {
                        return summary
                    }
                    return nil
                }
                finalReasoning = detailTexts.joined(separator: "\n\n")
            }

            let usage = response.usage.map {
                TrackChatUsage(
                    promptTokens: $0.promptTokens,
                    completionTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens,
                    cost: $0.cost
                )
            }

            // Calculate reasoning duration
            var reasoningDuration: TimeInterval?
            if let start = reasoningStartTime {
                let end = reasoningEndTime ?? Date()
                reasoningDuration = end.timeIntervalSince(start)
            }

            if let index = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[index].content = finalText
                var metadata = messages[index].metadata ?? TrackChatMessageMetadata()
                metadata.reasoning = finalReasoning.isEmpty ? nil : finalReasoning
                metadata.reasoningDuration = reasoningDuration
                metadata.usage = usage
                metadata.modelId = modelId
                messages[index].metadata = metadata
                assistantMessage = messages[index]
            }

            try await dbManager.insertTrackChatMessage(assistantMessage)
            try await dbManager.touchTrackChatSession(sessionId: session.id)
        } catch {
            errorMessage = error.localizedDescription
            if let index = messages.firstIndex(where: { $0.id == assistantId }) {
                messages.remove(at: index)
            }
        }

        isSending = false
    }

    /// Retry the last assistant message by removing it and re-sending the previous user prompt
    func retryLastMessage(
        modelId: String,
        track: AudiobookTrack?,
        collection: AudiobookCollection?
    ) async {
        guard !isSending else { return }

        // Find the last assistant message
        guard let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }

        // Find the user message that preceded it
        let userMessages = messages[0..<lastAssistantIndex].filter { $0.role == .user }
        guard let lastUserMessage = userMessages.last else { return }

        // Remove the last assistant message from UI
        messages.remove(at: lastAssistantIndex)

        // Re-send using the original user prompt
        await sendMessage(
            prompt: lastUserMessage.content,
            modelId: modelId,
            track: track,
            collection: collection
        )
    }

    private func scheduleStreamingUpdate(assistantId: String) {
        // If there's already a pending update, let it handle the accumulated text
        guard streamingUpdateTask == nil else { return }

        streamingUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: streamingThrottleInterval)
            guard !Task.isCancelled else { return }

            if let index = self.messages.firstIndex(where: { $0.id == assistantId }) {
                self.messages[index].content = self.pendingStreamText
                if !self.pendingStreamReasoning.isEmpty {
                    var metadata = self.messages[index].metadata ?? TrackChatMessageMetadata()
                    metadata.reasoning = self.pendingStreamReasoning
                    self.messages[index].metadata = metadata
                }
            }
            self.streamingUpdateTask = nil
        }
    }

    private func loadTranscriptSegments() async throws -> [TranscriptSegment] {
        try await dbManager.initializeDatabase()
        guard let transcript = try await dbManager.loadTranscript(forTrackId: trackId) else {
            return []
        }
        return try await dbManager.loadTranscriptSegments(forTranscriptId: transcript.id)
    }

    private func trackHasTranscript() async -> Bool {
        do {
            return try await dbManager.hasCompletedTranscript(forTrackId: trackId)
        } catch {
            return false
        }
    }

    private func defaultSessionTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(format: NSLocalizedString("track_chat_default_session_title", comment: "Chat %@"), formatter.string(from: Date()))
    }

    private func updateSessionLocalState(
        sessionId: String,
        contextSelection: TrackChatContextSelection,
        modelId: String?
    ) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].contextSelection = contextSelection
            if let modelId {
                sessions[index].modelId = modelId
            }
        }
        if selectedSession?.id == sessionId {
            selectedSession?.contextSelection = contextSelection
            if let modelId {
                selectedSession?.modelId = modelId
            }
        }
    }
}
