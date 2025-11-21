import SwiftUI
import GRDB
import Foundation

// MARK: - Preview Helpers

extension AIGatewayViewModel {
    static var preview: AIGatewayViewModel {
        let defaults = UserDefaults(suiteName: "preview_ai_gateway")!
        defaults.removePersistentDomain(forName: "preview_ai_gateway")
        
        // Pre-populate cache with properly structured models
        let models = [
            AIModelInfo(
                id: "openai/gpt-4o",
                name: "GPT-4o",
                description: "Most advanced GPT-4 model with vision capabilities",
                ownedBy: "openai",
                created: nil,
                maxTokens: 4096,
                contextWindow: 128000,
                tags: ["chat", "vision"],
                type: "chat",
                pricing: AIModelPricing(input: "0.0025", output: "0.01", inputCacheRead: nil),
                metadata: AIModelMetadata(provider: "OpenAI", modality: ["text", "image"], inputCost: 0.0025, outputCost: 0.01)
            ),
            AIModelInfo(
                id: "anthropic/claude-3-5-sonnet",
                name: "Claude 3.5 Sonnet",
                description: "Anthropic's most intelligent model",
                ownedBy: "anthropic",
                created: nil,
                maxTokens: 8192,
                contextWindow: 200000,
                tags: ["chat", "vision"],
                type: "chat",
                pricing: AIModelPricing(input: "0.003", output: "0.015", inputCacheRead: "0.0003"),
                metadata: AIModelMetadata(provider: "Anthropic", modality: ["text", "image"], inputCost: 0.003, outputCost: 0.015)
            )
        ]
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: "ai_gateway_cached_models")
        }
        
        let credits = CreditsResponse(balance: "15.50", totalUsed: "4.50")
        if let data = try? JSONEncoder().encode(credits) {
            defaults.set(data, forKey: "ai_gateway_cached_credits")
        }
        
        // Mock KeyStore
        let keyStore = MockAIGatewayAPIKeyStore()
        try? keyStore.saveKey("sk-preview-key-12345")
        
        let vm = AIGatewayViewModel(
            keyStore: keyStore,
            client: AIGatewayClient(), // Client won't be called if cache hits
            defaults: defaults
        )
        return vm
    }
}

class MockAIGatewayAPIKeyStore: AIGatewayAPIKeyStore {
    private var key: String?
    func saveKey(_ key: String) throws { self.key = key }
    func loadKey() throws -> String? { return key }
    func clearKey() throws { self.key = nil }
}

class MockSonioxAPIKeyStore: SonioxAPIKeyStore {
    private var key: String?
    func saveKey(_ key: String) throws { self.key = key }
    func loadKey() throws -> String? { return key }
    func clearKey() throws { self.key = nil }
}

extension AIGenerationManager {
    static var preview: AIGenerationManager {
        // Use in-memory DB for preview
        let dbManager = GRDBDatabaseManager(dbURL: URL(fileURLWithPath: ":memory:"))
        
        let manager = AIGenerationManager(dbManager: dbManager)
        
        // Inject dummy jobs via DB
        Task {
            try? await dbManager.initializeDatabase()
            
            _ = try? await dbManager.createAIGenerationJob(
                type: .chatTester,
                modelId: "openai/gpt-4o",
                trackId: nil,
                transcriptId: nil,
                sourceContext: "preview",
                displayName: "Chat Test",
                systemPrompt: "You are a helper.",
                userPrompt: "Hello world",
                payloadJSON: "{}"
            )
            
            _ = try? await dbManager.createAIGenerationJob(
                type: .trackSummary,
                modelId: "anthropic/claude-3-5-sonnet",
                trackId: UUID().uuidString,
                transcriptId: UUID().uuidString,
                sourceContext: "preview",
                displayName: "Chapter 1 Summary",
                systemPrompt: nil,
                userPrompt: nil,
                payloadJSON: "{}"
            )
            
            await manager.refreshJobs()
        }
        
        return manager
    }
}

extension TranscriptionManager {
    static var preview: TranscriptionManager {
        let dbManager = GRDBDatabaseManager(dbURL: URL(fileURLWithPath: ":memory:"))
        
        // Provide API key directly for preview
        let manager = TranscriptionManager(
            databaseManager: dbManager,
            sonioxAPIKey: "soniox-preview-key-67890"
        )
        
        Task {
            try? await dbManager.initializeDatabase()
            
            let trackId = UUID()
            _ = try? await dbManager.createTranscriptionJob(
                trackId: trackId.uuidString,
                sonioxJobId: "job-123",
                status: "processing",
                progress: 0.45
            )
            
            _ = try? await dbManager.createTranscriptionJob(
                trackId: UUID().uuidString,
                sonioxJobId: "job-456",
                status: "completed",
                progress: 1.0
            )
            
            await manager.refreshAllRecentJobs()
        }
        
        return manager
    }
}

extension LibraryStore {
    static var preview: LibraryStore {
        let dbManager = GRDBDatabaseManager(dbURL: URL(fileURLWithPath: ":memory:"))
        
        let store = LibraryStore(dbManager: dbManager, autoLoadOnInit: false)
        
        Task {
            try? await dbManager.initializeDatabase()
            
            // Create dummy bookmark data (empty Data is fine for preview)
            let dummyBookmark = Data()
            
            let collection = AudiobookCollection(
                id: UUID(),
                title: "Preview Collection",
                author: "Preview Author",
                description: "A nice collection for preview.",
                coverAsset: CollectionCover(kind: .solid(colorHex: "#FF5733"), dominantColorHex: nil),
                createdAt: Date(),
                updatedAt: Date(),
                source: .local(directoryBookmark: dummyBookmark),
                tracks: [
                    AudiobookTrack(
                        id: UUID(),
                        displayName: "Chapter 1",
                        filename: "ch1.mp3",
                        location: .local(urlBookmark: dummyBookmark),
                        fileSize: 1024,
                        duration: 300,
                        trackNumber: 1,
                        checksum: nil,
                        metadata: [:],
                        isFavorite: false,
                        favoritedAt: nil
                    ),
                    AudiobookTrack(
                        id: UUID(),
                        displayName: "Chapter 2",
                        filename: "ch2.mp3",
                        location: .local(urlBookmark: dummyBookmark),
                        fileSize: 2048,
                        duration: 600,
                        trackNumber: 2,
                        checksum: nil,
                        metadata: [:],
                        isFavorite: true,
                        favoritedAt: Date()
                    )
                ],
                lastPlayedTrackId: nil,
                playbackStates: [:],
                tags: ["Fiction", "Preview"]
            )
            
            store.save(collection)
            await store.load()
        }
        
        return store
    }
}
