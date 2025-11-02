import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var collections: [AudiobookCollection] = []
    @Published private(set) var lastError: Error?

    private let persistence: LibraryPersistence
    private let schemaVersion = 1

    init(persistence: LibraryPersistence = .default, autoLoadOnInit: Bool = true) {
        self.persistence = persistence
        if autoLoadOnInit {
            Task(priority: .userInitiated) {
                await load()
            }
        }
    }

    func load() async {
        do {
            let file = try await persistence.load()
            guard file.schemaVersion == schemaVersion else {
                throw LibraryStoreError.unsupportedSchema(file.schemaVersion)
            }

            collections = file.collections.sorted { $0.updatedAt > $1.updatedAt }
            lastError = nil
        } catch {
            collections = []
            lastError = error
        }
    }

    func save(_ collection: AudiobookCollection) {
        var updated = collections
        if let index = updated.firstIndex(where: { $0.id == collection.id }) {
            updated[index] = collection
        } else {
            updated.append(collection)
        }

        collections = updated.sorted { $0.updatedAt > $1.updatedAt }
        persistCurrentSnapshot()
    }

    func delete(_ collection: AudiobookCollection) {
        collections.removeAll { $0.id == collection.id }
        persistCurrentSnapshot()
    }

    func collection(forPath path: String) -> AudiobookCollection? {
        collections.first { collection in
            guard case let .baiduNetdisk(folderPath, _) = collection.source else {
                return false
            }
            return folderPath == path
        }
    }

    func clearErrors() {
        lastError = nil
    }

    private func persistCurrentSnapshot() {
        let snapshot = LibraryFile(schemaVersion: schemaVersion, collections: collections)
        Task(priority: .utility) {
            do {
                try await persistence.save(snapshot)
            } catch {
                await MainActor.run {
                    self.lastError = error
                }
            }
        }
    }
}

enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Library schema version \(version) is not supported."
        }
    }
}

struct LibraryFile: Codable {
    var schemaVersion: Int
    var collections: [AudiobookCollection]
}

actor LibraryPersistence {
    static let `default` = LibraryPersistence()

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? LibraryPersistence.makeDefaultURL(fileManager: fileManager)
        ensureDirectoryExists()
    }

    func load() throws -> LibraryFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LibraryFile(schemaVersion: 1, collections: [])
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryFile.self, from: data)
    }

    func save(_ file: LibraryFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(file)

        let tempURL = fileURL.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        try fileManager.moveItem(at: tempURL, to: fileURL)
    }

    private func ensureDirectoryExists() {
        let directoryURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func makeDefaultURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}
