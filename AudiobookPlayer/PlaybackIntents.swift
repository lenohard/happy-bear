#if os(iOS)
import AppIntents
import Foundation

// MARK: - Intent Coordinator

/// Bridges App Intents → in-app playback. Intents set pending actions here,
/// and the app observes and executes them on the main actor.
@MainActor
final class IntentCoordinator: ObservableObject {
    static let shared = IntentCoordinator()

    enum PendingAction {
        case resumeLastPlayed
        case playCollection(id: UUID)
    }

    @Published var pendingAction: PendingAction?

    private init() {}

    func requestResume() {
        pendingAction = .resumeLastPlayed
    }

    func requestPlayCollection(id: UUID) {
        pendingAction = .playCollection(id: id)
    }
}

// MARK: - AppEntity: Collection

struct CollectionEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Collection"
    static var defaultQuery = CollectionQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    init(_ collection: AudiobookCollection) {
        self.init(id: collection.id, title: collection.title)
    }
}

struct CollectionQuery: EntityQuery {
    private static func loadCollections() async throws -> [AudiobookCollection] {
        let db = GRDBDatabaseManager.shared
        try await db.initializeDatabase()
        return try await db.loadAllCollections()
    }

    func entities(for identifiers: [UUID]) async throws -> [CollectionEntity] {
        let idSet = Set(identifiers)
        let collections = try await Self.loadCollections()
        return collections
            .filter { idSet.contains($0.id) }
            .map(CollectionEntity.init)
    }

    func suggestedEntities() async throws -> [CollectionEntity] {
        let collections = try await Self.loadCollections()
        return collections
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map(CollectionEntity.init)
    }

    func entities(matching string: String) async throws -> [CollectionEntity] {
        let lowered = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return try await suggestedEntities() }
        let collections = try await Self.loadCollections()
        return collections
            .filter { $0.title.lowercased().contains(lowered) }
            .map(CollectionEntity.init)
    }
}

// MARK: - Intents

struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Playback"
    static var description = IntentDescription("Continue your most recent happyBear playback.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentCoordinator.shared.requestResume()
        return .result(dialog: IntentDialog("Resuming happyBear."))
    }
}

struct PlayCollectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Collection"
    static var description = IntentDescription("Resume a specific collection from its last position.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentCoordinator.shared.requestPlayCollection(id: collection.id)
        return .result(dialog: IntentDialog("Resuming \(collection.title)."))
    }
}

// MARK: - Shortcuts Phrases

struct HappyBearShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                // English
                "Resume ${applicationName}",
                "Continue ${applicationName}",
                "Play ${applicationName}",
                // Chinese
                "用${applicationName}继续播放",
                "${applicationName}继续",
                "播放${applicationName}"
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayCollectionIntent(),
            phrases: [
                // English
                "Play \(\.$collection) in ${applicationName}",
                "Resume \(\.$collection) in ${applicationName}",
                // Chinese
                "用${applicationName}播放\(\.$collection)",
                "${applicationName}播放\(\.$collection)",
                "在${applicationName}里播放\(\.$collection)"
            ],
            shortTitle: "Play Collection",
            systemImageName: "books.vertical"
        )
    }
}

#endif
