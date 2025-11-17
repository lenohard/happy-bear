import Foundation
import OSLog

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
    @Published private(set) var storedKeyValue: String = ""
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

    @Published var selectedModelID: String {
        didSet {
            defaults.set(selectedModelID, forKey: defaultModelKey)
        }
    }

    @Published private(set) var lastModelRefreshDate: Date?
    @Published private(set) var lastCreditsRefreshDate: Date?

    private let keyStore: AIGatewayAPIKeyStore
    private let client: AIGatewayClient
    private let defaults: UserDefaults
    private var hasStoredKey: Bool = false
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "AIGateway")

    private let defaultModelKey = "ai_gateway_default_model"
    private let defaultModelFallback = "openai/gpt-4o-mini"
    private let modelsCacheKey = "ai_gateway_cached_models"
    private let modelsCacheTimestampKey = "ai_gateway_cached_models_timestamp"
    private let creditsCacheKey = "ai_gateway_cached_credits"
    private let creditsCacheTimestampKey = "ai_gateway_cached_credits_timestamp"

    init(
        keyStore: AIGatewayAPIKeyStore = KeychainAIGatewayAPIKeyStore(),
        client: AIGatewayClient = AIGatewayClient(),
        defaults: UserDefaults = .standard
    ) {
        self.keyStore = keyStore
        self.client = client
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: defaultModelKey) ?? defaultModelFallback

        loadStoredKey()
        loadCachedPayloads()
    }

    var hasValidKey: Bool {
        switch keyState {
        case .valid:
            return true
        default:
            return false
        }
    }

    func loadStoredKey() {
        do {
            if let stored = try keyStore.loadKey() {
                logger.debug("Loaded stored AI key; length=\(stored.count)")
                hasStoredKey = true
                keyState = .valid
                storedKeyValue = stored
                // Don't populate apiKey field - keep it empty for security
                // User will see empty field with "Key verified" status
            } else {
                logger.debug("No stored AI key found")
                hasStoredKey = false
                keyState = .unknown
                storedKeyValue = ""
            }
        } catch {
            logger.error("Failed loading stored AI key: \(error.localizedDescription)")
            hasStoredKey = false
            keyState = .invalid(error.localizedDescription)
            storedKeyValue = ""
        }
    }

    func markKeyAsEditing() {
        // Always allow editing when user types something
        logger.debug("User editing AI key; current length=\(self.apiKey.count)")
        keyState = .editing
    }

    func saveAndValidateKey(using providedKey: String? = nil) async {
        let input = providedKey ?? apiKey
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("saveAndValidateKey invoked; rawLength=\(input.count) trimmedLength=\(trimmed.count)")
        guard !trimmed.isEmpty else {
            logger.warning("Save aborted: trimmed AI key is empty")
            keyState = .invalid(NSLocalizedString("ai_tab_empty_key", comment: ""))
            return
        }

        keyState = .validating
        logger.debug("Persisting AI key and validating against model list")

        do {
            try keyStore.saveKey(trimmed)
            hasStoredKey = true
            storedKeyValue = trimmed
            // Validate by fetching models with the new key
            try await refreshModels(with: trimmed)
            // Refresh credits immediately after validation
            await refreshCredits()
            // Clear field after successful save for security
            apiKey = ""
            logger.debug("AI key saved and validated successfully")
            keyState = .valid
        } catch {
            logger.error("AI key validation failed: \(error.localizedDescription)")
            keyState = .invalid(error.localizedDescription)
        }
    }

    func refreshModels() async throws {
        let resolvedKey: String
        do {
            if let storedKey = try keyStore.loadKey(), !storedKey.isEmpty {
                resolvedKey = storedKey
            } else if !apiKey.isEmpty {
                resolvedKey = apiKey
            } else {
                modelErrorMessage = NSLocalizedString("ai_tab_missing_key", comment: "")
                return
            }
        } catch {
            modelErrorMessage = error.localizedDescription
            throw error
        }

        isFetchingModels = true
        modelErrorMessage = nil
        defer { isFetchingModels = false }

        do {
            let list = try await client.fetchModels(apiKey: resolvedKey)
            models = list
            persistModelsCache(list)
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
        logger.debug("Refreshing model list using provided key; currently have \(self.models.count) cached models")
        isFetchingModels = true
        modelErrorMessage = nil
        defer { isFetchingModels = false }

        do {
            let list = try await client.fetchModels(apiKey: key)
            models = list
            persistModelsCache(list)
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
        logger.debug("Refreshing credits; stored key available=\(self.hasStoredKey)")
        isFetchingCredits = true
        defer { isFetchingCredits = false }

        do {
            // Try to load key from storage to use for API call
            if let storedKey = try keyStore.loadKey() {
                logger.debug("Loaded stored key for credits request")
                credits = try await client.fetchCredits(apiKey: storedKey)
                persistCreditsCache(credits)
            }
        } catch {
            logger.error("Failed fetching credits: \(error.localizedDescription)")
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
            logger.debug("Running chat test with model \(self.selectedModelID)")

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
            logger.debug("Fetching generation details for id=\(trimmedID)")
            let response = try await client.fetchGeneration(apiKey: storedKey, id: trimmedID)
            generationDetails = response.data
        } catch {
            logger.error("Failed fetching generation \(trimmedID): \(error.localizedDescription)")
            generationError = error.localizedDescription
        }
    }

}

// MARK: - Caching Helpers

private extension AIGatewayViewModel {
    func persistModelsCache(_ list: [AIModelInfo]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: modelsCacheKey)
        let now = Date()
        defaults.set(now, forKey: modelsCacheTimestampKey)
        lastModelRefreshDate = now
    }

    func persistCreditsCache(_ credits: CreditsResponse?) {
        guard let credits,
              let data = try? JSONEncoder().encode(credits) else {
            defaults.removeObject(forKey: creditsCacheKey)
            defaults.removeObject(forKey: creditsCacheTimestampKey)
            lastCreditsRefreshDate = nil
            return
        }

        defaults.set(data, forKey: creditsCacheKey)
        let now = Date()
        defaults.set(now, forKey: creditsCacheTimestampKey)
        lastCreditsRefreshDate = now
    }

    func loadCachedPayloads() {
        loadCachedModels()
        loadCachedCredits()
    }

    func loadCachedModels() {
        guard let data = defaults.data(forKey: modelsCacheKey) else { return }
        do {
            models = try JSONDecoder().decode([AIModelInfo].self, from: data)
            lastModelRefreshDate = defaults.object(forKey: modelsCacheTimestampKey) as? Date
        } catch {
            logger.error("Failed decoding cached models: \(error.localizedDescription)")
            defaults.removeObject(forKey: modelsCacheKey)
        }
    }

    func loadCachedCredits() {
        guard let data = defaults.data(forKey: creditsCacheKey) else { return }
        do {
            credits = try JSONDecoder().decode(CreditsResponse.self, from: data)
            lastCreditsRefreshDate = defaults.object(forKey: creditsCacheTimestampKey) as? Date
        } catch {
            logger.error("Failed decoding cached credits: \(error.localizedDescription)")
            defaults.removeObject(forKey: creditsCacheKey)
        }
    }
}
