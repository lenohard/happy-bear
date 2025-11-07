import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AITabView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @FocusState private var focusedField: KeyField?
    @State private var isModelListExpanded = true
    @State private var collapsedModelProviders: Set<String> = []
    @State private var isCredentialSectionExpanded = true

    var body: some View {
        NavigationStack {
            List {
                credentialsSection

                if gateway.hasValidKey {
                    modelsSection
                    testerSection
                    creditsSection
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
        }
    }

    private var credentialsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isCredentialSectionExpanded) {
                SecureField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .gateway)
                    .onChange(of: gateway.apiKey) { _ in
                        gateway.markKeyAsEditing()
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
        Section(footer: modelsFooter) {
            if let summary = selectedModelSummary {
                Label(summary, systemImage: "star.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            ForEach(groupedModels, id: \.provider) { group in
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

    private var modelsFooter: some View {
        HStack {
            Button(NSLocalizedString("ai_tab_refresh_models", comment: "")) {
                Task { try? await gateway.refreshModels() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var groupedModels: [(provider: String, models: [AIModelInfo])]
    {
        let grouped = Dictionary(grouping: gateway.models) { providerName(for: $0.id) }
        return grouped
            .map { (provider: $0.key, models: $0.value.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func providerExpansionBinding(for provider: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedModelProviders.contains(provider) },
            set: { isExpanded in
                if isExpanded {
                    collapsedModelProviders.remove(provider)
                } else {
                    collapsedModelProviders.insert(provider)
                }
            }
        )
    }

    private func providerName(for modelID: String) -> String {
        if let prefix = modelID.split(separator: "/").first, !prefix.isEmpty {
            return String(prefix)
        }
        return NSLocalizedString("ai_tab_model_group_other", comment: "")
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
