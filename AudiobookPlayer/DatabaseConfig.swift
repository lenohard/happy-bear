import Foundation

/// Configuration for the GRDB SQLite database
struct DatabaseConfig {
    /// Gets the default database URL (iCloud container, fallback to ApplicationSupport)
    static var defaultURL: URL {
        return iCloudStorage.rootURL.appendingPathComponent("library.sqlite", isDirectory: false)
    }

    /// Legacy ApplicationSupport database URL (used for migration)
    static var legacyURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.sqlite", isDirectory: false)
    }

    /// Ensures the database directory exists
    static func ensureDirectoryExists() throws {
        let dir = defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
