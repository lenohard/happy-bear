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
    @AppStorage("ai_tab_models_section_expanded_v3") private var isModelListExpanded = false
    @AppStorage("ai_tab_collapsed_provider_data_v2") private var collapsedProviderData: Data = Data()
    @State private var modelSearchText: String = ""
    @State private var isCredentialSectionExpanded = false
    @State private var hasAppliedDefaultCollapse = false
    @State private var showAPIKey = false
    @State private var isEditingGatewayKey = false
    @State private var isInitialScrollPerformed = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    credentialsSection

                    if gateway.hasValidKey {
                        testerSection
                        aiJobsSection
                        creditsSection
                        modelsSection
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        focusedField = nil
                        resignFirstResponder()   // hide keyboard when tapping outside fields
                    }
                )
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
                .onChange(of: gateway.models.isEmpty) { isEmpty in
                    if !isEmpty {
                        applyDefaultProviderCollapseIfNeeded(with: gateway.models)
                        performInitialScrollIfNeeded(using: proxy)
                    }
                }
                .onAppear {
                    isEditingGatewayKey = !gateway.hasValidKey
                    performInitialScrollIfNeeded(using: proxy)
                }
                .onChange(of: gateway.keyState) { state in
                    handleGatewayKeyStateChange(state)
                }
                .onChange(of: gateway.selectedModelID) { newValue in
                    expandProviderIfNeeded(for: newValue)
                    scrollToModel(withID: newValue, using: proxy)
                }
            }
        }
    }

    private var credentialsSection: some View {
        Section {
            gatewayKeyRow
                .modifier(CredentialRowModifier(alignment: .leading))

            HStack(spacing: 12) {
                Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                    let pendingKey = gateway.apiKey
                    focusedField = nil
                    resignFirstResponder()
                    Task {
                        await gateway.saveAndValidateKey(using: pendingKey)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(gateway.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button(NSLocalizedString("credential_edit_button", comment: "")) {
                    toggleGatewayEditing()
                }
                .buttonStyle(.borderless)
                .disabled(!gateway.hasValidKey && gateway.apiKey.isEmpty)
            }
            .modifier(CredentialRowModifier(alignment: .leading))
        } header: {
            Label(NSLocalizedString("ai_tab_credentials_section", comment: ""), systemImage: "key.horizontal")
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
                    Text(maskedAPIKey(gateway.storedKeyValue))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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

    private var modelsSection: some View {
        Section {
            if let summary = selectedModelSummary {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 12) {
                        Label(summary.title, systemImage: "star.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { try? await gateway.refreshModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let description = summary.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let pricing = summary.pricing {
                        Text(pricing)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let refreshText = lastRefreshDescription(for: gateway.lastModelRefreshDate) {
                        Text(refreshText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }

            if !gateway.models.isEmpty {
                TextField(
                    NSLocalizedString("ai_tab_models_search_placeholder", comment: ""),
                    text: $modelSearchText
                )
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .listRowSeparator(.hidden)
            }

            DisclosureGroup(isExpanded: $isModelListExpanded) {
                modelsListContent
            } label: {
                collapsibleSectionHeader(
                    title: NSLocalizedString("ai_tab_models_section", comment: ""),
                    isExpanded: $isModelListExpanded
                )
            }
        }
    }

    @ViewBuilder
    private var modelsListContent: some View {
        if gateway.isFetchingModels {
            ProgressView()
        } else if let error = gateway.modelErrorMessage {
            Text(error)
                .foregroundColor(.red)
        } else if gateway.models.isEmpty {
            Button(NSLocalizedString("ai_tab_load_models", comment: "")) {
                Task { try? await gateway.refreshModels() }
            }
        } else {
            let groups = filteredModelGroups
            if groups.isEmpty {
                Text(NSLocalizedString("ai_tab_models_search_no_results", comment: ""))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(groups, id: \.provider) { group in
                    let binding = providerExpansionBinding(for: group.provider)
                    DisclosureGroup(isExpanded: binding) {
                        ForEach(group.models) { model in
                            modelRow(for: model)
                                .id(model.id)
                        }
                    } label: {
                        providerDisclosureLabel(for: group.provider, binding: binding)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var groupedModels: [(provider: String, models: [AIModelInfo])]
    {
        let grouped = Dictionary(grouping: gateway.models) { providerName(for: $0.id) }
        return grouped
            .map { (provider: $0.key, models: $0.value.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private var filteredModelGroups: [(provider: String, models: [AIModelInfo])] {
        let groups = groupedModels
        let trimmed = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        let query = trimmed.lowercased()

        return groups.compactMap { group in
            let providerMatches = group.provider.lowercased().contains(query)
            let models = providerMatches ? group.models : group.models.filter { modelMatches($0, query: query) }
            guard !models.isEmpty else { return nil }
            return (provider: group.provider, models: models)
        }
    }

    private func providerExpansionBinding(for provider: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedModelProviders.contains(provider) },
            set: { isExpanded in
                var providers = collapsedModelProviders
                if isExpanded {
                    providers.remove(provider)
                } else {
                    providers.insert(provider)
                }
                collapsedModelProviders = providers
            }
        )
    }

    private var collapsedModelProviders: Set<String> {
        get {
            guard !collapsedProviderData.isEmpty,
                  let decoded = try? JSONDecoder().decode(Set<String>.self, from: collapsedProviderData) else {
                return []
            }
            return decoded
        }
        nonmutating set {
            collapsedProviderData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func providerName(for modelID: String) -> String {
        if let prefix = modelID.split(separator: "/").first, !prefix.isEmpty {
            return String(prefix)
        }
        return NSLocalizedString("ai_tab_model_group_other", comment: "")
    }

    private func providerDisplayName(for model: AIModelInfo) -> String? {
        if let ownedBy = model.ownedBy, !ownedBy.isEmpty {
            return ownedBy
        }
        if let provider = model.metadata?.provider, !provider.isEmpty {
            return provider
        }
        let fallback = providerName(for: model.id)
        return fallback.isEmpty ? nil : fallback
    }

    private func formattedPricePerMillion(_ raw: String?, fallback: Double? = nil) -> String {
        let sanitized: String? = {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            value = value.replacingOccurrences(of: "$", with: "")
            value = value.replacingOccurrences(of: ",", with: "")
            if let firstComponent = value.split(whereSeparator: { " /".contains($0) }).first {
                return String(firstComponent)
            }
            return value
        }()

        guard let base = Double(sanitized ?? "") ?? fallback else {
            return "-"
        }

        let perMillion = base * 1_000_000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = perMillion < 1 ? 4 : 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: perMillion)) ?? "-"
    }

    private func applyDefaultProviderCollapseIfNeeded(with models: [AIModelInfo]) {
        guard !models.isEmpty,
              collapsedProviderData.isEmpty,
              !hasAppliedDefaultCollapse else { return }

        let providers = Set(models.map { providerName(for: $0.id) })
        // Collapse ALL providers by default on app restart
        collapsedModelProviders = providers
        hasAppliedDefaultCollapse = true
    }

    private func modelMatches(_ model: AIModelInfo, query: String) -> Bool {
        let displayName = (model.name ?? model.id).lowercased()
        if displayName.contains(query) { return true }
        if model.id.lowercased().contains(query) { return true }
        if let description = model.description?.lowercased(), description.contains(query) { return true }
        return false
    }

    private func performInitialScrollIfNeeded(using proxy: ScrollViewProxy) {
        guard !isInitialScrollPerformed, !gateway.models.isEmpty else { return }
        isInitialScrollPerformed = true
        // Don't auto-expand provider or scroll to model on app restart
        // Keep all groups collapsed initially as requested
    }

    private func scrollToModel(withID id: String, using proxy: ScrollViewProxy, animated: Bool = true) {
        guard gateway.models.contains(where: { $0.id == id }) else { return }
        let scrollAction = {
            proxy.scrollTo(id, anchor: .top)
        }
        if animated {
            withAnimation(.easeInOut) { scrollAction() }
        } else {
            scrollAction()
        }
    }

    private func expandProviderIfNeeded(for modelID: String) {
        let provider = providerName(for: modelID)
        var collapsed = collapsedModelProviders
        if collapsed.contains(provider) {
            collapsed.remove(provider)
            collapsedModelProviders = collapsed
        }
    }

    private var selectedModelSummary: (title: String, description: String?, pricing: String?)? {
        guard let model = gateway.models.first(where: { $0.id == gateway.selectedModelID }) else {
            return nil
        }
        let displayName = model.name?.isEmpty == false ? model.name! : model.id
        let provider = providerDisplayName(for: model)
        let title: String
        if let provider {
            title = String(
                format: NSLocalizedString("ai_tab_selected_model_summary", comment: ""),
                displayName,
                provider
            )
        } else {
            title = displayName
        }

        var pricingText: String?
        if let pricing = model.pricing {
            let inputPrice = formattedPricePerMillion(pricing.input, fallback: model.metadata?.inputCost)
            let outputPrice = formattedPricePerMillion(pricing.output, fallback: model.metadata?.outputCost)
            pricingText = String(
                format: NSLocalizedString("ai_tab_pricing_template", comment: ""),
                inputPrice,
                outputPrice
            )
        }

        return (title: title, description: model.description, pricing: pricingText)
    }

    @ViewBuilder
    private func modelRow(for model: AIModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.name ?? model.id)
                    .font(.headline)
                Spacer()
                if model.id == gateway.selectedModelID {
                    Label(NSLocalizedString("ai_tab_default_model", comment: ""), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }
            if let description = model.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let pricing = model.pricing {
                let inputPrice = formattedPricePerMillion(pricing.input, fallback: model.metadata?.inputCost)
                let outputPrice = formattedPricePerMillion(pricing.output, fallback: model.metadata?.outputCost)
                Text(String(
                    format: NSLocalizedString("ai_tab_pricing_template", comment: ""),
                    inputPrice,
                    outputPrice
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button(NSLocalizedString("ai_tab_set_default", comment: "")) {
                gateway.selectedModelID = model.id
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func collapsibleSectionHeader(title: String, isExpanded: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut) {
                isExpanded.wrappedValue.toggle()
            }
        }
    }

    private func providerDisclosureLabel(for provider: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            ProviderIconView(providerId: provider)
            Text(provider)
                .font(.headline)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut) {
                binding.wrappedValue.toggle()
            }
        }
    }

private func lastRefreshDescription(for date: Date?) -> String? {
        guard let date else { return nil }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relativeString = formatter.localizedString(for: date, relativeTo: Date())

        return String(
            format: NSLocalizedString("ai_tab_last_updated_template", comment: ""),
            relativeString
        )
    }

    private var testerSection: some View {
        Section(header: Text(NSLocalizedString("ai_tab_tester_section", comment: ""))) {
            TextField(NSLocalizedString("ai_tab_system_prompt", comment: ""), text: $gateway.systemPrompt)

            TextField(NSLocalizedString("ai_tab_prompt_placeholder", comment: ""), text: $gateway.chatPrompt, axis: .vertical)
                .lineLimit(3, reservesSpace: true)

            Button {
                Task { await gateway.enqueueChatTest(using: aiGenerationManager) }
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

    private var aiJobsSection: some View {
        Section(header: Text("AI Jobs")) {
            if aiGenerationManager.activeJobs.isEmpty && aiJobHistory.isEmpty {
                Text("No AI jobs yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !aiGenerationManager.activeJobs.isEmpty {
                    ForEach(aiGenerationManager.activeJobs) { job in
                        aiJobRow(job, showDelete: false)
                    }
                }

                if !aiJobHistory.isEmpty {
                    ForEach(aiJobHistory) { job in
                        aiJobRow(job)
                    }
                }
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
        .environmentObject(AIGatewayViewModel())
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

    var aiJobHistory: [AIGenerationJob] {
        Array(aiGenerationManager.recentJobs.filter { $0.isTerminal }.prefix(5))
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
            return "Queued"
        case .running, .streaming:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
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

    @ViewBuilder
    func aiJobRow(_ job: AIGenerationJob, showDelete: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(jobTitle(for: job))
                    .font(.headline)
                Spacer()
                Text(chatJobStatusText(job))
                    .font(.caption)
                    .foregroundStyle(statusColor(for: job))
            }

            if let detail = jobDetail(for: job), !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if showDelete {
                    Button(role: .destructive) {
                        Task { await aiGenerationManager.deleteJob(job) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func jobTitle(for job: AIGenerationJob) -> String {
        switch job.type {
        case .chatTester:
            return "Chat Tester"
        case .transcriptRepair:
            return job.displayName ?? "Transcript Repair"
        case .trackSummary:
            return "Track Summary"
        }
    }

    func jobDetail(for job: AIGenerationJob) -> String? {
        switch job.type {
        case .chatTester:
            if let output = job.streamedOutput ?? job.finalOutput, !output.isEmpty {
                return truncate(output)
            }
            if let prompt = job.userPrompt, !prompt.isEmpty {
                return truncate(prompt)
            }
            return nil
        case .transcriptRepair:
            if let results = job.decodedMetadata()?.repairResults {
                if results.isEmpty {
                    return "No changes."
                }
                return "Updated \(results.count) segment(s)."
            }
            if let payload = job.decodedPayload(TranscriptRepairJobPayload.self) {
                return "Queued \(payload.selectionIndexes.count) segment(s)."
            }
            return nil
        case .trackSummary:
            return job.finalOutput
        }
    }

    func truncate(_ text: String, limit: Int = 160) -> String {
        if text.count <= limit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }
}

func resignFirstResponder() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#elseif canImport(AppKit)
    NSApp.keyWindow?.makeFirstResponder(nil)
#endif
}

struct TTSTabView: View {
    @StateObject private var sonioxViewModel = SonioxKeyViewModel()
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @FocusState private var isKeyFieldFocused: Bool
    @State private var isTestInProgress = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var selectedJobForTranscript: TranscriptionJob?
    @State private var refreshTimer: Timer?
    @State private var showSonioxKey = false
    @State private var isEditingSonioxKey = false
    @State private var showJobHistorySheet = false
    @State private var jobActionError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sonioxKeyRow
                        .modifier(CredentialRowModifier(alignment: .leading))

                    HStack(spacing: 12) {
                        Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                            let pendingKey = sonioxViewModel.apiKey
                            isKeyFieldFocused = false
                            resignFirstResponder()
                            Task { await sonioxViewModel.saveKey(using: pendingKey) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(sonioxViewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        Button(NSLocalizedString("credential_edit_button", comment: "")) {
                            toggleSonioxEditing()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!sonioxViewModel.keyExists)
                    }
                    .modifier(CredentialRowModifier(alignment: .leading))
                } header: {
                    Label(NSLocalizedString("soniox_section_title", comment: ""), systemImage: "waveform")
                        .font(.headline)
                }

                if sonioxViewModel.keyExists {
                    Section {
                        Button(action: { Task { await testTranscription() } }) {
                            if isTestInProgress {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8, anchor: .center)
                                    Text("Testing transcription...")
                                }
                            } else {
                                Label("Test with sample audio", systemImage: "play.circle")
                            }
                        }
                        .disabled(isTestInProgress)

                        if let error = testError {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Test Failed", systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        if let result = testResult {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Transcription Result", systemImage: "checkmark.circle")
                                    .font(.footnote)
                                    .foregroundColor(.green)
                                Text(result)
                                    .font(.caption)
                                    .lineLimit(5)
                                    .truncationMode(.tail)
                            }
                        }
                    } header: {
                        Text("Test Soniox API")
                    }

                    // Transcription Jobs Section
                    transcriptionJobsSection
                }
            }
            .navigationTitle(Text(NSLocalizedString("tts_tab_title", comment: "")))
            .task {
                // Reload key status when view appears (handles case where key was saved before this feature was added)
                await sonioxViewModel.refreshKeyStatus()
                // Load all recent jobs
                await transcriptionManager.refreshAllRecentJobs()
                // Start auto-refresh timer if there are active jobs
                startAutoRefreshIfNeeded()
            }
            .refreshable {
                await transcriptionManager.refreshAllRecentJobs()
            }
            .sheet(isPresented: $showJobHistorySheet) {
                TranscriptionHistorySheet(
                    jobs: transcriptionManager.allRecentJobs,
                    lookupTrackName: { lookupTrackName(for: $0) },
                    onOpenTranscript: { job in selectedJobForTranscript = job },
                    onRetry: retryJob,
                    onDelete: deleteJob
                )
            }
            .onChange(of: transcriptionManager.activeJobs.count) { newCount in
                // Auto-refresh all jobs when active job count changes (e.g., when job completes)
                Task {
                    await transcriptionManager.refreshAllRecentJobs()
                }
                // Start or stop timer based on active jobs
                if newCount > 0 {
                    startAutoRefresh()
                } else {
                    stopAutoRefresh()
                }
            }
            .onDisappear {
                stopAutoRefresh()
            }
            .alert(isPresented: Binding(
                get: { jobActionError != nil },
                set: { if !$0 { jobActionError = nil } }
            )) {
                Alert(
                    title: Text(NSLocalizedString("tts_jobs_action_error_title", comment: "")),
                    message: Text(jobActionError ?? ""),
                    dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK button")))
                )
            }
            .sheet(item: $selectedJobForTranscript) { job in
                TranscriptViewerSheet(
                    trackId: job.trackId,
                    trackName: lookupTrackName(for: job.trackId)
                )
            }
            .onAppear {
                isEditingSonioxKey = !sonioxViewModel.keyExists
            }
            .onChange(of: sonioxViewModel.keyExists) { exists in
                isEditingSonioxKey = !exists
            }
            .onChange(of: sonioxViewModel.statusMessage) { _ in
                if sonioxViewModel.isSuccess {
                    isEditingSonioxKey = false
                    showSonioxKey = false
                }
            }
        }
    }

    private var shouldShowSonioxKeyInput: Bool {
        isEditingSonioxKey || !sonioxViewModel.keyExists
    }

    private var sonioxKeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if shouldShowSonioxKeyInput {
                    sonioxKeyInputField
                } else if !sonioxViewModel.storedKeyValue.isEmpty {
                    Text(maskedSonioxKey(sonioxViewModel.storedKeyValue))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(NSLocalizedString("soniox_key_placeholder", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showSonioxKey.toggle() }) {
                Image(systemName: showSonioxKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var sonioxKeyInputField: some View {
        Group {
            if showSonioxKey {
                TextField(NSLocalizedString("soniox_key_placeholder", comment: ""), text: $sonioxViewModel.apiKey)
            } else {
                SecureField(NSLocalizedString("soniox_key_placeholder", comment: ""), text: $sonioxViewModel.apiKey)
            }
        }
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .focused($isKeyFieldFocused)
    }

    private func toggleSonioxEditing() {
        guard sonioxViewModel.keyExists else { return }

        if isEditingSonioxKey {
            isEditingSonioxKey = false
            sonioxViewModel.apiKey = ""
            isKeyFieldFocused = false
            showSonioxKey = false
            resignFirstResponder()
        } else {
            sonioxViewModel.apiKey = sonioxViewModel.storedKeyValue
            isEditingSonioxKey = true
            isKeyFieldFocused = true
        }
    }

    // MARK: - Transcription Jobs Section

    @ViewBuilder
    private var transcriptionJobsSection: some View {
        Section {
            let activeJobs = transcriptionManager.activeJobs
            if !activeJobs.isEmpty {
                ForEach(activeJobs) { job in
                    jobRow(for: job, status: job.status)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if job.isRunning {
                                Button(action: { pauseJob(job) }) {
                                    Label(NSLocalizedString("tts_jobs_action_pause", comment: ""), systemImage: "pause.fill")
                                }
                                .tint(.orange)
                            } else if job.status == "paused" {
                                Button(action: { resumeJob(job) }) {
                                    Label(NSLocalizedString("tts_jobs_action_continue", comment: ""), systemImage: "play.fill")
                                }
                                .tint(.blue)
                            }

                            Button(role: .destructive, action: { deleteJob(job) }) {
                                Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                            }
                        }
                }
            } else if !transcriptionManager.allRecentJobs.isEmpty {
                Text(NSLocalizedString("tts_jobs_no_active", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No transcription jobs yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            let historyJobs = transcriptionManager.allRecentJobs.filter { $0.status == "completed" || $0.status == "failed" }
            if !historyJobs.isEmpty {
                Button {
                    showJobHistorySheet = true
                } label: {
                    HStack {
                        Label(NSLocalizedString("tts_jobs_history_button", comment: ""), systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("\(historyJobs.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Transcription Jobs")
                Spacer()
                if !transcriptionManager.activeJobs.isEmpty {
                    Text("\(transcriptionManager.activeJobs.count) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func maskedSonioxKey(_ apiKey: String) -> String {
        if showSonioxKey {
            return apiKey
        }
        guard apiKey.count > 8 else { return String(repeating: "•", count: apiKey.count) }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    @MainActor
    private func lookupTrackName(for trackId: String) -> String {
        for collection in library.collections {
            if let track = collection.tracks.first(where: { $0.id.uuidString == trackId }) {
                return track.displayName
            }
        }
        return trackId
    }

    @ViewBuilder
    private func jobRow(for job: TranscriptionJob, status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lookupTrackName(for: job.trackId))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    Text(statusText(for: job))
                        .font(.caption)
                        .foregroundStyle(statusColor(for: job.status))
                }

                Spacer()

                statusIcon(for: job.status)

                // Add chevron for completed jobs (tappable)
                if job.status == "completed" {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress bar for active jobs
            if (job.status == "downloading" || job.status == "uploading" || job.status == "transcribing" || job.status == "processing"), let progress = job.progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Error message for failed jobs
            if job.status == "failed", let errorMessage = job.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Timestamp
            Text(formatDate(job.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func statusText(for job: TranscriptionJob) -> String {
        switch job.status {
        case "queued":
            return "Queued"
        case "downloading":
            return NSLocalizedString("status_downloading_audio", comment: "")
        case "uploading":
            return NSLocalizedString("status_uploading_audio", comment: "")
        case "transcribing", "processing":
            return "Transcribing..."
        case "completed":
            return "Completed"
        case "failed":
            return "Failed (retry \(job.retryCount))"
        case "paused":
            return NSLocalizedString("tts_jobs_status_paused", comment: "")
        default:
            return job.status.capitalized
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "queued":
            return .orange
        case "downloading", "uploading":
            return .blue
        case "transcribing", "processing":
            return .blue
        case "completed":
            return .green
        case "failed":
            return .red
        case "paused":
            return .gray
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status {
        case "queued":
            Image(systemName: "clock")
                .foregroundStyle(.orange)
        case "downloading", "uploading":
            ProgressView()
                .scaleEffect(0.8)
        case "transcribing", "processing":
            ProgressView()
                .scaleEffect(0.8)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case "paused":
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func pauseJob(_ job: TranscriptionJob) {
        Task {
            do {
                try await transcriptionManager.pauseJob(jobId: job.id)
            } catch {
                await MainActor.run {
                    jobActionError = error.localizedDescription
                }
            }
        }
    }

    private func resumeJob(_ job: TranscriptionJob) {
        Task {
            do {
                try await transcriptionManager.resumeJob(jobId: job.id)
            } catch {
                await MainActor.run {
                    jobActionError = error.localizedDescription
                }
            }
        }
    }

    private func retryJob(_ job: TranscriptionJob) {
        Task {
            do {
                try await transcriptionManager.retryJob(jobId: job.id)
            } catch {
                await MainActor.run {
                    jobActionError = error.localizedDescription
                }
            }
        }
    }

    private func deleteJob(_ job: TranscriptionJob) {
        Task {
            do {
                try await transcriptionManager.deleteJob(jobId: job.id)
            } catch {
                await MainActor.run {
                    jobActionError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Auto-refresh Timer

    private func startAutoRefreshIfNeeded() {
        if !transcriptionManager.activeJobs.isEmpty {
            startAutoRefresh()
        }
    }

    private func startAutoRefresh() {
        // Stop existing timer if any
        stopAutoRefresh()

        // Create new timer that fires every 3 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                await transcriptionManager.refreshAllRecentJobs()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func testTranscription() async {
        isTestInProgress = true
        testError = nil
        testResult = nil

        do {
            // Get the API key from keychain
            let keychainStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore()
            guard let apiKey = try keychainStore.loadKey() else {
                throw SonioxAPI.APIError.missingAPIKey
            }

            let api = SonioxAPI(apiKey: apiKey)

            // Get the test audio file from the app bundle
            let fileManager = FileManager.default
            let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let testAudioURL = documentURL.appendingPathComponent("test-1min.mp3")

            // Check if file exists, if not try the app bundle, then try the project root
            let audioFileURL: URL
            if fileManager.fileExists(atPath: testAudioURL.path) {
                audioFileURL = testAudioURL
            } else if let bundleResourceURL = Bundle.main.url(forResource: "test-1min", withExtension: "mp3") {
                audioFileURL = bundleResourceURL
            } else {
                // Try the app directory if available (for development)
                if let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("test-1min.mp3") as URL?,
                   fileManager.fileExists(atPath: appBundleURL.path) {
                    audioFileURL = appBundleURL
                } else {
                    throw SonioxAPI.APIError.fileUploadFailed
                }
            }

            // Upload the audio file
            let fileId = try await api.uploadFile(fileURL: audioFileURL)

            // Create transcription job
            let transcriptionId = try await api.createTranscription(
                fileId: fileId,
                languageHints: ["zh", "en"]
            )

            // Poll for completion (with timeout)
            var attempts = 0
            let maxAttempts = 120  // 2 minutes with 1 second polling
            while attempts < maxAttempts {
                let status = try await api.checkTranscriptionStatus(transcriptionId: transcriptionId)

                if status.status == "completed" {
                    // Get the transcript
                    let transcript = try await api.getTranscript(transcriptionId: transcriptionId)

                    // Extract text from tokens
                    let fullText = transcript.tokens
                        .map { $0.text }
                        .joined(separator: " ")

                    await MainActor.run {
                        testResult = fullText.isEmpty ? "(Empty transcript)" : fullText
                        isTestInProgress = false
                    }
                    return
                } else if status.status == "error" {
                    throw SonioxAPI.APIError.transcriptionFailed(message: status.error_message ?? "Unknown error")
                }

                // Wait before polling again
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                attempts += 1
            }

            throw SonioxAPI.APIError.transcriptionFailed(message: "Transcription timeout after 2 minutes")

        } catch {
            await MainActor.run {
                testError = error.localizedDescription
                isTestInProgress = false
            }
        }
    }
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

// MARK: - Transcription History Sheet

struct TranscriptionHistorySheet: View {
    let jobs: [TranscriptionJob]
    let lookupTrackName: (String) -> String
    let onOpenTranscript: (TranscriptionJob) -> Void
    let onRetry: (TranscriptionJob) -> Void
    let onDelete: (TranscriptionJob) -> Void

    @Environment(\.dismiss) private var dismiss

    private var completedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == "completed" }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    private var failedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == "failed" }
            .sorted { ($0.lastAttemptAt ?? $0.createdAt) > ($1.lastAttemptAt ?? $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            List {
                if completedJobs.isEmpty && failedJobs.isEmpty {
                    Section {
                        Text(NSLocalizedString("tts_jobs_history_empty", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }
                } else {
                    if !completedJobs.isEmpty {
                        Section(header: Text(NSLocalizedString("tts_jobs_history_completed", comment: ""))) {
                            ForEach(completedJobs) { job in
                                historyRow(for: job)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        dismiss()
                                        DispatchQueue.main.async {
                                            onOpenTranscript(job)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            onDelete(job)
                                        } label: {
                                            Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }

                    if !failedJobs.isEmpty {
                        Section(header: Text(NSLocalizedString("tts_jobs_history_failed", comment: ""))) {
                            ForEach(failedJobs) { job in
                                historyRow(for: job, showError: true)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            onRetry(job)
                                        } label: {
                                            Label(NSLocalizedString("tts_jobs_action_retry", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .tint(.blue)

                                        Button(role: .destructive) {
                                            onDelete(job)
                                        } label: {
                                            Label(NSLocalizedString("tts_jobs_action_delete", comment: ""), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("tts_jobs_history_title", comment: "")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done_button") {
                        dismiss()
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func historyRow(for job: TranscriptionJob, showError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lookupTrackName(job.trackId))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    Text(statusText(for: job))
                        .font(.caption)
                        .foregroundStyle(statusColor(for: job.status))
                }

                Spacer()

                Text(relativeDate(for: job.completedAt ?? job.lastAttemptAt ?? job.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if showError, let errorMessage = job.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(for job: TranscriptionJob) -> String {
        switch job.status {
        case "completed":
            return NSLocalizedString("completed_status", comment: "")
        case "failed":
            return NSLocalizedString("failed_status", comment: "")
        default:
            return job.status.capitalized
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "completed":
            return .green
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private func relativeDate(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
