import SwiftUI

/// Wrapper view that ensures environment objects are injected into TrackChatView when presented in a sheet
struct TrackChatSheetWrapper: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var aiGateway: AIGatewayViewModel

    let trackId: String
    let collectionId: String

    var body: some View {
        NavigationStack {
            TrackChatView(trackId: trackId, collectionId: collectionId)
                .environmentObject(library)
                .environmentObject(aiGateway)
        }
    }
}

struct TrackChatView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var aiGateway: AIGatewayViewModel

    let trackId: String
    let collectionId: String?

    @StateObject private var viewModel: TrackChatViewModel
    @State private var showingModelPicker = false
    @State private var showingContextSheet = false
    @State private var showingHistory = false
    @State private var contextSelectionDebounceTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    init(trackId: String, collectionId: String?) {
        self.trackId = trackId
        self.collectionId = collectionId
        _viewModel = StateObject(wrappedValue: TrackChatViewModel(trackId: trackId, collectionId: collectionId))
    }

    private var collection: AudiobookCollection? {
        guard let collectionId, let uuid = UUID(uuidString: collectionId) else { return nil }
        return library.collections.first { $0.id == uuid }
    }

    private var track: AudiobookTrack? {
        if let collection {
            return collection.tracks.first { $0.id.uuidString == trackId }
        }
        for collection in library.collections {
            if let match = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return match
            }
        }
        return nil
    }

    private var modelTitle: String {
        if let model = aiGateway.models.first(where: { $0.id == aiGateway.selectedModelID }) {
            return model.name ?? model.id
        }
        return aiGateway.selectedModelID
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                promptInput
            }
            .navigationTitle(track?.displayName ?? NSLocalizedString("track_chat_title_fallback", comment: "Track Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingModelPicker = true
                    } label: {
                        Label(modelTitle, systemImage: "cpu")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingContextSheet = true
                    } label: {
                        Label(NSLocalizedString("track_chat_context_title", comment: "Context"), systemImage: "doc.text.magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingHistory = true
                    } label: {
                        Label(NSLocalizedString("track_chat_history_title", comment: "History"), systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await viewModel.startNewSession(track: track, collection: collection, modelId: aiGateway.selectedModelID)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.load(track: track, collection: collection)
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                NavigationStack {
                    AIModelsListView()
                        .environmentObject(aiGateway)
                        .navigationTitle(NSLocalizedString("track_chat_select_model", comment: "Select Model"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(NSLocalizedString("track_chat_done", comment: "Done")) { showingModelPicker = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingContextSheet) {
                NavigationStack {
                    TrackChatContextSheet(
                        selection: $viewModel.contextSelection,
                        contextPreview: viewModel.contextPreview,
                        transcriptWarning: viewModel.transcriptWarning,
                        transcriptTruncated: viewModel.transcriptTruncated,
                        onApply: { selection in
                            Task {
                                await viewModel.applyContextSelection(selection, track: track, collection: collection)
                                showingContextSheet = false
                            }
                        }
                    )
                    .navigationTitle(NSLocalizedString("track_chat_context_title", comment: "Context"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NSLocalizedString("track_chat_close", comment: "Close")) { showingContextSheet = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack {
                    TrackChatHistorySheet(
                        sessions: viewModel.sessions,
                        selectedSessionId: viewModel.selectedSession?.id,
                        onSelect: { session in
                            Task {
                                await viewModel.selectSession(session, track: track, collection: collection)
                                showingHistory = false
                            }
                        }
                    )
                    .navigationTitle(NSLocalizedString("track_chat_history_sheet_title", comment: "Chat History"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NSLocalizedString("track_chat_close", comment: "Close")) { showingHistory = false }
                        }
                    }
                }
            }
            .onChange(of: viewModel.contextSelection) { _, _ in
                // Debounce context refresh to avoid excess rebuilds
                contextSelectionDebounceTask?.cancel()
                contextSelectionDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                    guard !Task.isCancelled else { return }
                    await viewModel.refreshContextPreview(track: track, collection: collection)
                }
            }
            .onChange(of: viewModel.selectedSession?.modelId) { _, newValue in
                if let modelId = newValue, !modelId.isEmpty {
                    aiGateway.selectedModelID = modelId
                }
            }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(viewModel.messages.filter { !($0.role == .assistant && $0.content.isEmpty) }) { message in
                        TrackChatMessageRow(
                            message: message,
                            onCopy: {
                                UIPasteboard.general.string = message.content
                            },
                            onRetry: message.role == .assistant ? {
                                Task {
                                    await viewModel.retryLastMessage(
                                        modelId: aiGateway.selectedModelID,
                                        track: track,
                                        collection: collection
                                    )
                                }
                            } : nil
                        )
                        .id(message.id)
                    }

                    if viewModel.isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(NSLocalizedString("track_chat_thinking", comment: "Thinking..."))
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var promptInput: some View {
        let canSend = !viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isSending
        return VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            // Multiline input field with embedded send button
            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topLeading) {
                    if viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(NSLocalizedString("track_chat_input_placeholder", comment: "Ask about this track"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }

                    TextEditor(text: $viewModel.draftMessage)
                        .focused($isInputFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .padding(.trailing, 36)
                        .frame(minHeight: 44, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                }

                Button {
                    Task {
                        await viewModel.sendMessage(
                            prompt: viewModel.draftMessage,
                            modelId: aiGateway.selectedModelID,
                            track: track,
                            collection: collection
                        )
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : Color.gray.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(canSend ? Color.accentColor : Color(.systemGray5))
                        )
                }
                .disabled(!canSend)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct TrackChatMessageRow: View {
    let message: TrackChatMessage
    let onCopy: () -> Void
    let onRetry: (() -> Void)?

    @State private var isReasoningExpanded = false

    private var isUser: Bool {
        message.role == .user
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.createdAt)
    }

    private var reasoningDurationText: String? {
        guard let duration = message.metadata?.reasoningDuration else { return nil }
        return String(format: "%.1fs", duration)
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            // Header
            messageHeader

            // Reasoning Card (assistant only)
            if !isUser, let reasoning = message.metadata?.reasoning, !reasoning.isEmpty {
                reasoningCard(reasoning: reasoning)
            }

            // Message Bubble
            messageBubble

            // Action Buttons (assistant only)
            if !isUser {
                actionButtonsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Message Header

    @ViewBuilder
    private var messageHeader: some View {
        if isUser {
            // User: timestamp + avatar on right
            HStack(spacing: 6) {
                Spacer()
                Text(formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        } else {
            // Assistant: model icon + model name + timestamp + tokens
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                if let modelId = message.metadata?.modelId {
                    Text(modelId)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }

                Text(formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let usage = message.metadata?.usage, let total = usage.totalTokens {
                    Text("\(total) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    // MARK: - Reasoning Card

    @ViewBuilder
    private func reasoningCard(reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReasoningExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)

                    Text(NSLocalizedString("track_chat_deep_thinking", comment: "Deep Thinking"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if let durationText = reasoningDurationText {
                        Text("(\(durationText))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isReasoningExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isReasoningExpanded {
                Divider()
                    .padding(.horizontal, 12)

                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.purple.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: - Message Bubble

    private var messageBubble: some View {
        HStack {
            if isUser { Spacer() }

            Text(message.content)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                )
                .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
                .textSelection(.enabled)

            if !isUser { Spacer() }
        }
    }

    // MARK: - Action Buttons

    private var actionButtonsRow: some View {
        HStack(spacing: 16) {
            if !message.content.isEmpty {
                // Copy button
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Retry button
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Usage info (cost)
            if let usage = message.metadata?.usage {
                if let cost = usage.cost, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.top, 4)
    }
}


private struct TrackChatContextSheet: View {
    @Binding var selection: TrackChatContextSelection
    let contextPreview: String
    let transcriptWarning: String?
    let transcriptTruncated: Bool
    let onApply: (TrackChatContextSelection) -> Void
    private var transcriptAvailable: Bool { transcriptWarning == nil }

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("track_chat_context_sources", comment: "Context Sources"))) {
                Toggle(NSLocalizedString("track_chat_source_track_info", comment: "Track info"), isOn: $selection.includeTrackInfo)
                Toggle(NSLocalizedString("track_chat_source_collection_info", comment: "Collection info"), isOn: $selection.includeCollectionInfo)
                Toggle(NSLocalizedString("track_chat_source_transcript", comment: "Transcript"), isOn: $selection.includeTranscript)
                    .disabled(!transcriptAvailable)
            }

            if selection.includeTranscript {
                Section(header: Text(NSLocalizedString("track_chat_transcript_scope", comment: "Transcript Scope"))) {
                    Picker(NSLocalizedString("track_chat_transcript_scope", comment: "Scope"), selection: $selection.transcriptScope) {
                        Text(NSLocalizedString("track_chat_scope_auto", comment: "Auto")).tag(TrackChatTranscriptScope.auto)
                        Text(NSLocalizedString("track_chat_scope_full", comment: "Full")).tag(TrackChatTranscriptScope.full)
                        Text(NSLocalizedString("track_chat_scope_recent", comment: "Recent")).tag(TrackChatTranscriptScope.recent)
                    }
                    .pickerStyle(.segmented)

                    if selection.transcriptScope == .recent {
                        Stepper(value: Binding(
                            get: { selection.recentMinutes ?? 10 },
                            set: { selection.recentMinutes = $0 }
                        ), in: 1...60) {
                            Text(String(format: NSLocalizedString("track_chat_scope_recent_minutes", comment: "Last %lld minutes"), selection.recentMinutes ?? 10))
                        }
                    }
                }
            }

            Section(header: Text(NSLocalizedString("track_chat_preview", comment: "Preview"))) {
                if let warning = transcriptWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if transcriptTruncated {
                    Text(NSLocalizedString("track_chat_transcript_truncated", comment: "Transcript truncated"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(contextPreview.isEmpty ? NSLocalizedString("track_chat_no_context", comment: "No context available.") : contextPreview)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onApply(selection)
            } label: {
                Text(NSLocalizedString("track_chat_apply", comment: "Apply"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .onAppear {
            if !transcriptAvailable {
                selection.includeTranscript = false
                selection.transcriptScope = .auto
                selection.recentMinutes = nil
            }
        }
        .onChange(of: selection.includeTranscript) { _, newValue in
            if !newValue {
                selection.transcriptScope = .auto
                selection.recentMinutes = nil
            } else if selection.recentMinutes == nil {
                selection.recentMinutes = 10
            }
        }
    }
}

private struct TrackChatHistorySheet: View {
    let sessions: [TrackChatSession]
    let selectedSessionId: String?
    let onSelect: (TrackChatSession) -> Void

    var body: some View {
        List {
            ForEach(sessions, id: \.id) { session in
                Button {
                    onSelect(session)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title ?? "Chat")
                                .font(.headline)
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.id == selectedSessionId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}
