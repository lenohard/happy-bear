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
    private var hasStoredKey: Bool = false

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
                hasStoredKey = true
                keyState = .valid
                // Don't populate apiKey field - keep it empty for security
                // User will see empty field with "Key verified" status
            } else {
                hasStoredKey = false
                keyState = .unknown
            }
        } catch {
            hasStoredKey = false
            keyState = .invalid(error.localizedDescription)
        }
    }

    func markKeyAsEditing() {
        // Always allow editing when user types something
        keyState = .editing
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
            hasStoredKey = true
            // Validate by fetching models with the new key
            try await refreshModels(with: trimmed)
            // Clear field after successful save for security
            apiKey = ""
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

    func refreshModels(with key: String) async throws {
        guard !key.isEmpty else { return }
        isFetchingModels = true
        modelErrorMessage = nil
        defer { isFetchingModels = false }

        do {
            let list = try await client.fetchModels(apiKey: key)
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
        // Use hasStoredKey to know if we have a valid key in storage
        // Don't rely on apiKey field since we clear it for security
        guard hasStoredKey else { return }
        isFetchingCredits = true
        defer { isFetchingCredits = false }

        do {
            // Try to load key from storage to use for API call
            if let storedKey = try keyStore.loadKey() {
                credits = try await client.fetchCredits(apiKey: storedKey)
            }
        } catch {
            credits = nil
        }
    }

    func runChatTest() async {
        guard hasStoredKey, !chatPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chatResponseText = ""
            return
        }

        do {
            guard let storedKey = try keyStore.loadKey() else { return }

            let result = try await client.sendChat(
                apiKey: storedKey,
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
        guard hasStoredKey else {
            generationError = NSLocalizedString("ai_tab_missing_key", comment: "")
            return
        }

        do {
            guard let storedKey = try keyStore.loadKey() else {
                generationError = NSLocalizedString("ai_tab_missing_key", comment: "")
                return
            }
            let response = try await client.fetchGeneration(apiKey: storedKey, id: trimmedID)
            generationDetails = response.data
        } catch {
            generationError = error.localizedDescription
        }
    }

    func clearKey() {
        do {
            try keyStore.clearKey()
            hasStoredKey = false
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
