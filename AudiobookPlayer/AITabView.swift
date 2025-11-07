import SwiftUI

struct AITabView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @StateObject private var sonioxViewModel = SonioxKeyViewModel()

    var body: some View {
        NavigationStack {
            List {
                credentialsSection
                sonioxSection

                if gateway.hasValidKey {
                    modelsSection
                    testerSection
                    creditsSection
                    generationSection
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
        Section(header: Text(NSLocalizedString("ai_tab_credentials_section", comment: ""))) {
            SecureField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onChange(of: gateway.apiKey) { _ in
                    gateway.markKeyAsEditing()
                }

            HStack {
                Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                    Task { await gateway.saveAndValidateKey() }
                }

                Button(NSLocalizedString("ai_tab_clear_key", comment: ""), role: .destructive) {
                    gateway.clearKey()
                }
            }

            keyStateLabel
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
        Section(header: Text(NSLocalizedString("ai_tab_models_section", comment: "")), footer: modelsFooter) {
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
                ForEach(gateway.models) { model in
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

    private var generationSection: some View {
        Section(header: Text(NSLocalizedString("ai_tab_generation_section", comment: ""))) {
            TextField(NSLocalizedString("ai_tab_generation_placeholder", comment: ""), text: $gateway.generationLookupID)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button(NSLocalizedString("ai_tab_lookup_generation", comment: "")) {
                Task { await gateway.lookupGeneration() }
            }

            if let details = gateway.generationDetails {
                generationDetailsView(details)
            } else if let error = gateway.generationError {
                Text(error)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private func generationDetailsView(_ details: GenerationDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(details.id)
                .font(.headline)
            if let model = details.model {
                Text(model)
                    .font(.subheadline)
            }
            if let created = details.createdAt {
                Text(created.formatted())
                    .font(.footnote)
            }
            if let cost = details.totalCost {
                Text(String(format: NSLocalizedString("ai_tab_generation_cost", comment: ""), cost))
                    .font(.footnote)
            }
            if let latency = details.latency, let duration = details.generationTime {
                Text(String(format: NSLocalizedString("ai_tab_generation_latency", comment: ""), latency, duration))
                    .font(.footnote)
            }
            if let promptTokens = details.tokensPrompt, let completionTokens = details.tokensCompletion {
                Text(String(format: NSLocalizedString("ai_tab_generation_tokens", comment: ""), promptTokens, completionTokens))
                    .font(.footnote)
            }
        }
    }

    private var sonioxSection: some View {
        Section(header: Text(NSLocalizedString("soniox_section_title", comment: ""))) {
            SecureField(
                NSLocalizedString("soniox_key_placeholder", comment: ""),
                text: $sonioxViewModel.apiKey
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)

            HStack {
                Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                    Task { await sonioxViewModel.saveKey() }
                }

                Button(NSLocalizedString("ai_tab_clear_key", comment: ""), role: .destructive) {
                    Task { await sonioxViewModel.clearKey() }
                }
            }

            sonioxStatusLabel
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

#Preview {
    AITabView()
        .environmentObject(AIGatewayViewModel())
}
