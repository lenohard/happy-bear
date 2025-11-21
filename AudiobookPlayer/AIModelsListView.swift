import SwiftUI

struct AIModelsListView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @State private var searchText = ""
    @State private var expandedProviders: Set<String> = []

    var body: some View {
        List {
            if gateway.isFetchingModels {
                HStack {
                    Spacer()
                    ProgressView("Loading Models...")
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if let error = gateway.modelErrorMessage {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text("Error Loading Models")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                .listRowSeparator(.hidden)
            } else if gateway.models.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "cpu")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Models Available")
                            .font(.headline)
                        Text("Tap refresh to load available models.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Refresh Models") {
                            Task { try? await gateway.refreshModels() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                .listRowSeparator(.hidden)
            } else {
                if !filteredModelGroups.isEmpty {
                    ForEach(filteredModelGroups, id: \.provider) { group in
                        ProviderSection(
                            provider: group.provider,
                            models: group.models,
                            isExpanded: isProviderExpanded(group.provider),
                            onToggle: { toggleProvider(group.provider) }
                        )
                    }
                } else {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("No Results")
                                .font(.headline)
                            Text("No models match '\(searchText)'")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .navigationTitle(NSLocalizedString("ai_tab_models_section", comment: "AI Models"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { try? await gateway.refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            if gateway.models.isEmpty {
                try? await gateway.refreshModels()
            }
        }
        .onChange(of: searchText) { newValue in
            handleSearchChange(newValue)
        }
    }

    private var groupedModels: [(provider: String, models: [AIModelInfo])] {
        let grouped = Dictionary(grouping: gateway.models) { providerName(for: $0.id) }
        return grouped
            .map { (provider: $0.key, models: $0.value.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private var filteredModelGroups: [(provider: String, models: [AIModelInfo])] {
        let groups = groupedModels
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        let query = trimmed.lowercased()

        return groups.compactMap { group in
            let providerMatches = group.provider.lowercased().contains(query)
            let models = providerMatches ? group.models : group.models.filter { modelMatches($0, query: query) }
            guard !models.isEmpty else { return nil }
            return (provider: group.provider, models: models)
        }
    }

    private func providerName(for modelID: String) -> String {
        if let prefix = modelID.split(separator: "/").first, !prefix.isEmpty {
            return String(prefix)
        }
        return NSLocalizedString("ai_tab_model_group_other", comment: "")
    }

    private func modelMatches(_ model: AIModelInfo, query: String) -> Bool {
        let displayName = (model.name ?? model.id).lowercased()
        if displayName.contains(query) { return true }
        if model.id.lowercased().contains(query) { return true }
        if let description = model.description?.lowercased(), description.contains(query) { return true }
        return false
    }
    
    private func isProviderExpanded(_ provider: String) -> Bool {
        expandedProviders.contains(provider)
    }
    
    private func toggleProvider(_ provider: String) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }
    
    private func handleSearchChange(_ query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Clear search - collapse all
            expandedProviders.removeAll()
        } else {
            // Searching - expand all providers with results
            let providers = filteredModelGroups.map { $0.provider }
            expandedProviders = Set(providers)
        }
    }
}

// MARK: - Provider Section
struct ProviderSection: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    let provider: String
    let models: [AIModelInfo]
    let isExpanded: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { _ in onToggle() }
            )) {
                ForEach(models) { model in
                    AIModelRowView(model: model, isSelected: model.id == gateway.selectedModelID) {
                        gateway.selectedModelID = model.id
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    // Provider logo from assets
                    ProviderIconView(providerId: provider)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider)
                            .font(.headline)
                        Text("\(models.count) models")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct AIModelRowView: View {
    let model: AIModelInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name ?? model.id)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                        }
                    }
                    
                    if let description = model.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    if let pricing = model.pricing {
                        HStack(spacing: 8) {
                            PricingBadge(label: "Input", value: pricing.input, fallback: model.metadata?.inputCost)
                            PricingBadge(label: "Output", value: pricing.output, fallback: model.metadata?.outputCost)
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain) // Important for List row behavior
    }
}

struct PricingBadge: View {
    let label: String
    let value: String?
    let fallback: Double?
    
    var body: some View {
        if let price = formattedPrice {
            Text("\(label): \(price)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }
    
    private var formattedPrice: String? {
        let raw = value
        let sanitized: String? = {
            guard var val = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else { return nil }
            val = val.replacingOccurrences(of: "$", with: "")
            val = val.replacingOccurrences(of: ",", with: "")
            if let firstComponent = val.split(whereSeparator: { " /".contains($0) }).first {
                return String(firstComponent)
            }
            return val
        }()
        
        guard let base = Double(sanitized ?? "") ?? fallback else { return nil }
        
        let perMillion = base * 1_000_000
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        
        if let str = formatter.string(from: NSNumber(value: perMillion)) {
            return "\(str)/1M"
        }
        return nil
    }
}
