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
            SecureField(NSLocalizedString("ai_tab_api_key_placeholder", comment: ""), text: $gateway.apiKey)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .gateway)
                .onChange(of: gateway.apiKey) { newValue in
                    if !newValue.isEmpty {
                        gateway.markKeyAsEditing()
                    }
                }
                .modifier(CredentialRowModifier())

            Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                let pendingKey = gateway.apiKey
                focusedField = nil
                resignFirstResponder()
                Task { await gateway.saveAndValidateKey(using: pendingKey) }
            }
            .buttonStyle(.borderless)
            .modifier(CredentialRowModifier())

            keyStateLabel
                .modifier(CredentialRowModifier(alignment: .leading))
        } header: {
            Label(NSLocalizedString("ai_tab_credentials_section", comment: ""), systemImage: "key.horizontal")
                .font(.headline)
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
                        Image(systemName: "arrow.clockwise")
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
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: NSLocalizedString("ai_tab_balance_label", comment: ""), credits.balance))
                        Text(String(format: NSLocalizedString("ai_tab_total_used_label", comment: ""), credits.totalUsed))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField(
                        NSLocalizedString("soniox_key_placeholder", comment: ""),
                        text: $sonioxViewModel.apiKey
                    )
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($isKeyFieldFocused)
                    .modifier(CredentialRowModifier())

                    Button(NSLocalizedString("ai_tab_save_key", comment: "")) {
                        let pendingKey = sonioxViewModel.apiKey
                        isKeyFieldFocused = false
                        resignFirstResponder()
                        Task { await sonioxViewModel.saveKey(using: pendingKey) }
                    }
                    .buttonStyle(.borderless)
                    .modifier(CredentialRowModifier())

                    sonioxStatusContent
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
            }
            .refreshable {
                await transcriptionManager.refreshAllRecentJobs()
            }
        }
    }

    private var sonioxStatusContent: some View {
        VStack(alignment: .leading, spacing: 4) {
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

    // MARK: - Transcription Jobs Section

    @ViewBuilder
    private var transcriptionJobsSection: some View {
        if !transcriptionManager.allRecentJobs.isEmpty {
            Section {
                // Active jobs (queued + transcribing)
                let activeJobs = transcriptionManager.allRecentJobs.filter {
                    $0.status == "queued" || $0.status == "transcribing"
                }
                if !activeJobs.isEmpty {
                    ForEach(activeJobs) { job in
                        jobRow(for: job, status: "active")
                    }
                }

                // Failed jobs
                let failedJobs = transcriptionManager.allRecentJobs.filter { $0.status == "failed" }
                if !failedJobs.isEmpty {
                    ForEach(failedJobs) { job in
                        jobRow(for: job, status: "failed")
                    }
                }

                // Completed jobs (last 10)
                let completedJobs = transcriptionManager.allRecentJobs.filter { $0.status == "completed" }.prefix(10)
                if !completedJobs.isEmpty {
                    ForEach(Array(completedJobs)) { job in
                        jobRow(for: job, status: "completed")
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
        } else {
            Section {
                Text("No transcription jobs yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transcription Jobs")
            }
        }
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
            }

            // Progress bar for active jobs
            if job.status == "transcribing", let progress = job.progress {
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
        case "transcribing":
            return "Transcribing..."
        case "completed":
            return "Completed"
        case "failed":
            return "Failed (retry \(job.retryCount))"
        default:
            return job.status.capitalized
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "queued":
            return .orange
        case "transcribing":
            return .blue
        case "completed":
            return .green
        case "failed":
            return .red
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
        case "transcribing":
            ProgressView()
                .scaleEffect(0.8)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
