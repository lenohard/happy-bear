import Foundation

@MainActor
final class AIGatewayViewModel: ObservableObject {
    enum KeyState: Equatable {
        case unknown
        case editing
        case validating
        case valid
        case invalid(String)
    }

    @Published var apiKey: String = ""
    @Published private(set) var keyState: KeyState = .unknown
    @Published private(set) var models: [AIModelInfo] = []
    @Published private(set) var isFetchingModels = false
    @Published private(set) var credits: CreditsResponse?
    @Published private(set) var isFetchingCredits = false
    @Published private(set) var chatResponseText: String = ""
    @Published private(set) var chatUsageSummary: String = ""
    @Published var chatPrompt: String = ""
    @Published var systemPrompt: String = NSLocalizedString("ai_tab_default_system_prompt", comment: "Default system prompt")
    @Published var generationLookupID: String = ""
    @Published private(set) var generationDetails: GenerationDetails?
    @Published private(set) var generationError: String?
    @Published private(set) var modelErrorMessage: String?

    private let keyStore: AIGatewayAPIKeyStore
    private let client: AIGatewayClient
    private let defaults: UserDefaults

    private let defaultModelKey = "ai_gateway_default_model"

    init(
        keyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore(),
        client: AIGatewayClient = AIGatewayClient(),
        defaults: UserDefaults = .standard
    ) {
        self.keyStore = keyStore
        self.client = client
        self.defaults = defaults

        loadStoredKey()
    }

    var hasValidKey: Bool {
        switch keyState {
        case .valid:
            return true
        default:
            return false
        }
    }

    var selectedModelID: String {
        get { defaults.string(forKey: defaultModelKey) ?? "openai/gpt-4o-mini" }
        set { defaults.set(newValue, forKey: defaultModelKey) }
    }

    func loadStoredKey() {
        do {
            if let stored = try keyStore.loadKey() {
                apiKey = stored
                keyState = .valid
            } else {
                keyState = .unknown
            }
        } catch {
            keyState = .invalid(error.localizedDescription)
        }
    }

    func markKeyAsEditing() {
        if case .valid = keyState {
            keyState = .editing
        }
    }

    func saveAndValidateKey() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyState = .invalid(NSLocalizedString("ai_tab_empty_key", comment: ""))
            return
        }

        keyState = .validating

        do {
            try keyStore.saveKey(trimmed)
            apiKey = trimmed
            try await refreshModels()
            keyState = .valid
        } catch {
            keyState = .invalid(error.localizedDescription)
        }
    }

    func refreshModels() async throws {
        guard !apiKey.isEmpty else { return }
        isFetchingModels = true
        modelErrorMessage = nil
        defer { isFetchingModels = false }

        do {
            let list = try await client.fetchModels(apiKey: apiKey)
            models = list
            if !list.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = list.first?.id ?? selectedModelID
            }
        } catch {
            modelErrorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshCredits() async {
        guard !apiKey.isEmpty else { return }
        isFetchingCredits = true
        defer { isFetchingCredits = false }

        do {
            credits = try await client.fetchCredits(apiKey: apiKey)
        } catch {
            credits = nil
        }
    }

    func runChatTest() async {
        guard !apiKey.isEmpty, !chatPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chatResponseText = ""
            return
        }

        do {
            let result = try await client.sendChat(
                apiKey: apiKey,
                model: selectedModelID,
                systemPrompt: systemPrompt,
                userPrompt: chatPrompt
            )

            if let content = result.choices.first?.message.content {
                chatResponseText = content
            } else {
                chatResponseText = NSLocalizedString("ai_tab_no_content", comment: "")
            }

            if let usage = result.usage {
                chatUsageSummary = String(
                    format: NSLocalizedString("ai_tab_usage_summary", comment: ""),
                    usage.promptTokens ?? 0,
                    usage.completionTokens ?? 0,
                    usage.totalTokens ?? 0,
                    usage.cost ?? 0
                )
            } else {
                chatUsageSummary = ""
            }
        } catch {
            chatResponseText = error.localizedDescription
            chatUsageSummary = ""
        }
    }

    func lookupGeneration() async {
        generationError = nil
        generationDetails = nil
        let trimmedID = generationLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            generationError = NSLocalizedString("ai_tab_generation_empty", comment: "")
            return
        }
        guard !apiKey.isEmpty else {
            generationError = NSLocalizedString("ai_tab_missing_key", comment: "")
            return
        }

        do {
            let response = try await client.fetchGeneration(apiKey: apiKey, id: trimmedID)
            generationDetails = response.data
        } catch {
            generationError = error.localizedDescription
        }
    }

    func clearKey() {
        do {
            try keyStore.clearKey()
            apiKey = ""
            keyState = .unknown
            models = []
            credits = nil
            chatResponseText = ""
            chatUsageSummary = ""
        } catch {
            keyState = .invalid(error.localizedDescription)
        }
    }
}
