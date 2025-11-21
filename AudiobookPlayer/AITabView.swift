import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AITabView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @FocusState private var focusedField: KeyField?
    @AppStorage("ai_tab_tester_reasoning_enabled_v1") private var isTesterReasoningEnabled = false
    @State private var isCredentialSectionExpanded = false
    @State private var showAPIKey = false
    @State private var isEditingGatewayKey = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    credentialsSection

                    if gateway.hasValidKey {
                        quickActionsSection
                        testerSection
                    }
                }

                .navigationTitle(Text(NSLocalizedString("ai_tab_title", comment: "AI tab title")))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if gateway.hasValidKey {
                            Button(action: { Task { await gateway.refreshCredits() } }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel(Text(NSLocalizedString("ai_tab_refresh", comment: "")))
                        }
                    }
                }
                .task {
                    if gateway.hasValidKey {
                        if gateway.models.isEmpty {
                            try? await gateway.refreshModels()
                        }
                        if gateway.credits == nil {
                            await gateway.refreshCredits()
                        }
                    }
                }
                .onChange(of: gateway.keyState) { state in
                    handleGatewayKeyStateChange(state)
                }
                .onChange(of: focusedField) { newValue in
                    if newValue == nil && isEditingGatewayKey {
                        Task {
                            await gateway.saveAndValidateKey(using: gateway.apiKey)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Credentials & Status Section
    private var credentialsSection: some View {
        Section {
            // API Key Row - always editable, no edit button
            gatewayKeyRow
                .modifier(CredentialRowModifier(alignment: .leading))

            // Save button (only show when key is being edited)

            
            // Balance (only show when valid key exists)
            if gateway.hasValidKey, let credits = gateway.credits {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: NSLocalizedString("ai_tab_balance_label", comment: ""), credits.balance))
                            .font(.subheadline)
                        if let refreshText = lastRefreshDescription(for: gateway.lastCreditsRefreshDate) {
                            Text(refreshText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await gateway.refreshCredits() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } header: {
            Label(NSLocalizedString("ai_tab_credentials_section", comment: ""), systemImage: "key.horizontal")
                .font(.headline)
        }
    }
    
    // MARK: - Quick Actions Section
    private var quickActionsSection: some View {
        Section {
            NavigationLink {
                AIJobsListView()
            } label: {
                Label(NSLocalizedString("ai_tab_jobs_section", comment: "AI Jobs section"), systemImage: "list.bullet.clipboard")
            }
            
            NavigationLink {
                AIModelsListView()
            } label: {
                Label(NSLocalizedString("ai_tab_models_section", comment: "AI Models section"), systemImage: "cpu")
            }
        } header: {
            Text("Quick Access")
                .font(.headline)
        }
    }

    private var shouldShowGatewayKeyInput: Bool {
        isEditingGatewayKey || !gateway.hasValidKey
    }

    private var gatewayKeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if shouldShowGatewayKeyInput {
                    gatewayKeyInputField
                } else if !gateway.storedKeyValue.isEmpty {
                    Button(action: {
                        gateway.apiKey = gateway.storedKeyValue
                        isEditingGatewayKey = true
                        focusedField = .gateway
                    }) {
                        HStack {
                            Text(maskedAPIKey(gateway.storedKeyValue))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showAPIKey.toggle() }) {
                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var gatewayKeyInputField: some View {
        HStack(spacing: 8) {
            Group {
                if showAPIKey {
                    TextField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                } else {
                    SecureField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                }
            }
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .focused($focusedField, equals: .gateway)
            .onChange(of: gateway.apiKey) { newValue in
                if !newValue.isEmpty {
                    gateway.markKeyAsEditing()
                }
            }
            
            if isEditingGatewayKey && gateway.hasValidKey {
                Button(action: {
                    isEditingGatewayKey = false
                    gateway.apiKey = ""
                    focusedField = nil
                    showAPIKey = false
                    resignFirstResponder()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleGatewayEditing() {
        guard gateway.hasValidKey else {
            isEditingGatewayKey = true
            focusedField = .gateway
            return
        }

        if isEditingGatewayKey {
            isEditingGatewayKey = false
            gateway.apiKey = ""
            focusedField = nil
            showAPIKey = false
            resignFirstResponder()
        } else {
            gateway.apiKey = gateway.storedKeyValue
            isEditingGatewayKey = true
            focusedField = .gateway
        }
    }

    private func handleGatewayKeyStateChange(_ state: AIGatewayViewModel.KeyState) {
        switch state {
        case .valid:
            isEditingGatewayKey = false
            showAPIKey = false
        case .editing, .invalid, .unknown:
            isEditingGatewayKey = true
        case .validating:
            break
        }
    }

    private func maskedAPIKey(_ apiKey: String) -> String {
        if showAPIKey {
            return apiKey
        }
        guard apiKey.count > 8 else { return String(repeating: "•", count: apiKey.count) }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)...\(suffix)"
    }



    private static let refreshDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = false
        return formatter
    }()

    private func lastRefreshDescription(for date: Date?) -> String? {
        guard let date else { return nil }

        let timestamp = Self.refreshDateFormatter.string(from: date)

        return String(
            format: NSLocalizedString("ai_tab_last_updated_template", comment: ""),
            timestamp
        )
    }

    private var testerSection: some View {
        Section(header: Text(NSLocalizedString("ai_tab_tester_section", comment: ""))) {
            TextField(NSLocalizedString("ai_tab_system_prompt", comment: ""), text: $gateway.systemPrompt)

            TextField(NSLocalizedString("ai_tab_prompt_placeholder", comment: ""), text: $gateway.chatPrompt, axis: .vertical)
                .lineLimit(3, reservesSpace: true)

            Toggle(isOn: $isTesterReasoningEnabled) {
                Text(NSLocalizedString("ai_tab_reasoning_toggle", comment: ""))
            }
            .toggleStyle(.switch)

            Button {
                let reasoningConfig = isTesterReasoningEnabled
                    ? AIGatewayReasoningConfig(enabled: true, maxTokens: nil, effort: nil, exclude: nil)
                    : nil
                Task { await gateway.enqueueChatTest(using: aiGenerationManager, reasoning: reasoningConfig) }
            } label: {
                if chatJobInProgress != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(NSLocalizedString("ai_tab_run_test_running", comment: ""))
                    }
                } else {
                    Text(NSLocalizedString("ai_tab_run_test", comment: ""))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chatJobInProgress != nil || gateway.chatPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let error = gateway.chatTesterError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let job = mostRecentChatJob {
                chatJobResultCard(job)
            }
        }
    }



    private var creditsSection: some View {
        Section(header: Text(NSLocalizedString("ai_tab_credits_section", comment: ""))) {
            if gateway.isFetchingCredits {
                ProgressView()
            } else if let credits = gateway.credits {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: NSLocalizedString("ai_tab_balance_label", comment: ""), credits.balance))
                        Text(String(format: NSLocalizedString("ai_tab_total_used_label", comment: ""), credits.totalUsed))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let refreshText = lastRefreshDescription(for: gateway.lastCreditsRefreshDate) {
                            Text(refreshText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await gateway.refreshCredits() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(NSLocalizedString("ai_tab_fetch_credits", comment: "")) {
                    Task { await gateway.refreshCredits() }
                }
            }
        }
    }

}

#Preview {
    AITabView()
        .environmentObject(AIGatewayViewModel.preview)
        .environmentObject(AIGenerationManager.preview)
}

private enum KeyField: Hashable {
    case gateway
}

private extension AITabView {
    var chatJobInProgress: AIGenerationJob? {
        aiGenerationManager.activeJobs.first { $0.type == .chatTester }
    }

    var mostRecentChatJob: AIGenerationJob? {
        let chatJobs = aiGenerationManager.recentJobs.filter { $0.type == .chatTester }
        if let lastId = gateway.lastChatJobId, let match = chatJobs.first(where: { $0.id == lastId }) {
            return match
        }
        return chatJobs.first
    }



    @ViewBuilder
    func chatJobResultCard(_ job: AIGenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(for: job))
                    .frame(width: 10, height: 10)
                Text(chatJobStatusText(job))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let text = job.streamedOutput ?? job.finalOutput, !text.isEmpty {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if job.status == .failed, let error = job.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text(NSLocalizedString("ai_tab_no_content", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let usage = job.decodedUsage() {
                let text = String(
                    format: NSLocalizedString("ai_tab_usage_summary", comment: ""),
                    usage.promptTokens ?? 0,
                    usage.completionTokens ?? 0,
                    usage.totalTokens ?? 0,
                    usage.cost ?? 0
                )
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reasoning = usage.reasoningTokens {
                    Text(
                        String(
                            format: NSLocalizedString("ai_tab_usage_reasoning", comment: ""),
                            reasoning
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if job.decodedMetadata()?.flagEnabled("stream_fallback") == true {
                Text(NSLocalizedString("ai_tab_streaming_disabled", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

    func chatJobStatusText(_ job: AIGenerationJob) -> String {
        switch job.status {
        case .queued:
            return NSLocalizedString("ai_job_status_queued", comment: "")
        case .running, .streaming:
            return NSLocalizedString("ai_job_status_running", comment: "")
        case .completed:
            return NSLocalizedString("ai_job_status_completed", comment: "")
        case .failed:
            return NSLocalizedString("ai_job_status_failed", comment: "")
        case .canceled:
            return NSLocalizedString("ai_job_status_canceled", comment: "")
        }
    }

    func statusColor(for job: AIGenerationJob) -> Color {
        switch job.status {
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .gray
        default:
            return .orange
        }
    }
}

func resignFirstResponder() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#elseif canImport(AppKit)
    NSApp.keyWindow?.makeFirstResponder(nil)
#endif
}



private struct CredentialRowModifier: ViewModifier {
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, 8)
            .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

