import SwiftUI

enum AIDetailSection {
    case jobs
    case models
    case both
}

struct AIDetailView: View {
    @EnvironmentObject private var gateway: AIGatewayViewModel
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    
    let section: AIDetailSection
    
    @AppStorage("ai_tab_models_section_expanded_v3") private var isModelListExpanded = false
    @AppStorage("ai_tab_collapsed_provider_data_v2") private var collapsedProviderData: Data = Data()
    @AppStorage("ai_tab_jobs_section_expanded_v1") private var isJobSectionExpanded = false
    
    @State private var modelSearchText: String = ""
    @State private var selectedJobForDetail: AIGenerationJob?
    @State private var hasAppliedDefaultCollapse = false
    @State private var isInitialScrollPerformed = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if section == .jobs || section == .both {
                    aiJobsSection
                }
                if section == .models || section == .both {
                    modelsSection
                }
            }
            .navigationTitle(navigationTitle)
            .task {
                if gateway.hasValidKey && (section == .models || section == .both) {
                    if gateway.models.isEmpty {
                        try? await gateway.refreshModels()
                    }
                }
            }
            .onChange(of: gateway.models.isEmpty) { isEmpty in
                if !isEmpty && (section == .models || section == .both) {
                    applyDefaultProviderCollapseIfNeeded(with: gateway.models)
                    performInitialScrollIfNeeded(using: proxy)
                }
            }
            .onAppear {
                if section == .models || section == .both {
                    performInitialScrollIfNeeded(using: proxy)
                }
            }
            .onChange(of: gateway.selectedModelID) { newValue in
                if section == .models || section == .both {
                    expandProviderIfNeeded(for: newValue)
                    scrollToModel(withID: newValue, using: proxy)
                }
            }
        }
        .sheet(item: $selectedJobForDetail) { job in
            AIGenerationJobDetailView(jobId: job.id)
        }
    }
    
    private var navigationTitle: String {
        switch section {
        case .jobs:
            return NSLocalizedString("ai_tab_jobs_section", comment: "")
        case .models:
            return NSLocalizedString("ai_tab_models_section", comment: "")
        }
    }

    // MARK: - AI Jobs Section

    private var aiJobsSection: some View {
        Section(header: jobsSectionHeader) {
            if !isJobSectionExpanded {
                Button(NSLocalizedString("ai_tab_jobs_show_button", comment: "")) {
                    withAnimation(.easeInOut) {
                        isJobSectionExpanded = true
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("ai_tab_jobs_collapsed_hint", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if aiGenerationManager.activeJobs.isEmpty && aiJobHistory.isEmpty {
                Text(NSLocalizedString("ai_tab_jobs_empty", comment: ""))
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

    private var jobsSectionHeader: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("ai_tab_jobs_section", comment: ""))
                .font(.headline)
            Spacer()
            Image(systemName: isJobSectionExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut) {
                isJobSectionExpanded.toggle()
            }
        }
    }

    private var aiJobHistory: [AIGenerationJob] {
        Array(aiGenerationManager.recentJobs.filter { $0.isTerminal }.prefix(5))
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
                if job.status == .queued {
                    Button(NSLocalizedString("ai_tab_cancel_job", comment: "")) {
                        Task { await aiGenerationManager.cancelJob(job) }
                    }
                    .buttonStyle(.borderedProminent)
                }
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
        .contentShape(Rectangle())
        .onTapGesture {
            selectedJobForDetail = job
        }
    }

    func jobTitle(for job: AIGenerationJob) -> String {
        switch job.type {
        case .chatTester:
            return NSLocalizedString("ai_job_type_chat_tester", comment: "")
        case .transcriptRepair:
            return job.displayName ?? NSLocalizedString("ai_job_type_transcript_repair", comment: "")
        case .trackSummary:
            return job.displayName ?? NSLocalizedString("ai_job_type_track_summary", comment: "")
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

    // MARK: - Models Section

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
}

#Preview {
    NavigationStack {
        AIDetailView(section: .both)
            .environmentObject(AIGatewayViewModel.preview)
            .environmentObject(AIGenerationManager.preview)
    }
}
