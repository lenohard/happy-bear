import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AITabView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @FocusState private var focusedField: KeyField?
    @AppStorage("ai_tab_models_section_expanded_v2") private var isModelListExpanded = true
    @AppStorage("ai_tab_collapsed_provider_data_v2") private var collapsedProviderData: Data = Data()
    @State private var modelSearchText: String = ""
    @State private var isCredentialSectionExpanded = false
    @State private var hasAppliedDefaultCollapse = false

    var body: some View {
        NavigationStack {
            List {
                credentialsSection

                if gateway.hasValidKey {
                    testerSection
                    creditsSection
                    modelsSection
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
            .onChange(of: gateway.models.isEmpty) { isEmpty in
                if !isEmpty {
                    applyDefaultProviderCollapseIfNeeded(with: gateway.models)
                }
            }
        }
    }

    private var credentialsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isCredentialSectionExpanded) {
                SecureField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .gateway)
                    .onChange(of: gateway.apiKey) { newValue in
                        // Only mark as editing if user is actively typing, not if field was cleared by save
                        if !newValue.isEmpty {
                            gateway.markKeyAsEditing()
                        }
                    }

                Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                    let pendingKey = gateway.apiKey
                    focusedField = nil
                    resignFirstResponder()
                    Task { await gateway.saveAndValidateKey(using: pendingKey) }
                }

                keyStateLabel
            } label: {
                Label(NSLocalizedString("ai_tab_credentials_section", comment: ""), systemImage: "key.horizontal")
                    .font(.headline)
            }
            .listRowSeparator(.visible)
        }
    }

    @ViewBuilder
    private var keyStateLabel: some View {
        switch gateway.keyState {
        case .unknown:
            Text(NSLocalizedString("ai_tab_enter_key_hint", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .editing:
            Text(NSLocalizedString("ai_tab_unsaved_changes", comment: ""))
                .font(.footnote)
                .foregroundColor(.orange)
        case .validating:
            ProgressView(NSLocalizedString("ai_tab_validating", comment: ""))
        case .valid:
            Label(NSLocalizedString("ai_tab_key_valid", comment: ""), systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundColor(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundColor(.red)
        }
    }

    private var modelsSection: some View {
        Section {
            if let summary = selectedModelSummary {
                HStack(alignment: .center, spacing: 12) {
                    Label(summary, systemImage: "star.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { try? await gateway.refreshModels() }
                    } label: {
                        Label(NSLocalizedString("ai_tab_refresh_models", comment: ""), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                Text(NSLocalizedString("ai_tab_models_section", comment: ""))
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
                    DisclosureGroup(isExpanded: providerExpansionBinding(for: group.provider)) {
                        ForEach(group.models) { model in
                            modelRow(for: model)
                        }
                    } label: {
                        Text(group.provider)
                            .font(.headline)
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

    private func applyDefaultProviderCollapseIfNeeded(with models: [AIModelInfo]) {
        guard !models.isEmpty,
              collapsedProviderData.isEmpty,
              !hasAppliedDefaultCollapse else { return }
        let providers = Set(models.map { providerName(for: $0.id) })
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

    private var selectedModelSummary: String? {
        guard let model = gateway.models.first(where: { $0.id == gateway.selectedModelID }) else {
            return nil
        }
        let displayName = model.name?.isEmpty == false ? model.name! : model.id
        return String(
            format: NSLocalizedString("ai_tab_selected_model_summary", comment: ""),
            displayName
        )
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
                Text(String(
                    format: NSLocalizedString("ai_tab_pricing_template", comment: ""),
                    pricing.input ?? "-",
                    pricing.output ?? "-"
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

    private var testerSection: some View {
        Section(header: Text(NSLocalizedString("ai_tab_tester_section", comment: ""))) {
            TextField(NSLocalizedString("ai_tab_system_prompt", comment: ""), text: $gateway.systemPrompt)

            TextField(NSLocalizedString("ai_tab_prompt_placeholder", comment: ""), text: $gateway.chatPrompt, axis: .vertical)
                .lineLimit(3, reservesSpace: true)

            Button(NSLocalizedString("ai_tab_run_test", comment: "")) {
                Task { await gateway.runChatTest() }
            }

            if !gateway.chatResponseText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("ai_tab_response_label", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(gateway.chatResponseText)
                    if !gateway.chatUsageSummary.isEmpty {
                        Text(gateway.chatUsageSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: NSLocalizedString("ai_tab_balance_label", comment: ""), credits.balance))
                    Text(String(format: NSLocalizedString("ai_tab_total_used_label", comment: ""), credits.totalUsed))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

func resignFirstResponder() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#elseif canImport(AppKit)
    NSApp.keyWindow?.makeFirstResponder(nil)
#endif
}

struct TTSTabView: View {
    @StateObject private var sonioxViewModel = SonioxKeyViewModel()
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisclosureGroup {
                        SecureField(
                            NSLocalizedString("soniox_key_placeholder", comment: ""),
                            text: $sonioxViewModel.apiKey
                        )
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($isKeyFieldFocused)

                        Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                            let pendingKey = sonioxViewModel.apiKey
                            isKeyFieldFocused = false
                            resignFirstResponder()
                            Task { await sonioxViewModel.saveKey(using: pendingKey) }
                        }

                        sonioxStatusLabel
                    } label: {
                        Label(NSLocalizedString("soniox_section_title", comment: ""), systemImage: "waveform")
                            .font(.headline)
                    }
                    .listRowSeparator(.visible)
                }
            }
            .navigationTitle(Text(NSLocalizedString("tts_tab_title", comment: "")))
        }
    }

    @ViewBuilder
    private var sonioxStatusLabel: some View {
        if sonioxViewModel.keyExists {
            Label(NSLocalizedString("soniox_configured", comment: ""), systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundColor(.green)
        } else {
            Label(NSLocalizedString("soniox_not_configured", comment: ""), systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundColor(.orange)
        }

        if let message = sonioxViewModel.statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundColor(sonioxViewModel.isSuccess ? .green : .red)
        }
    }
}
