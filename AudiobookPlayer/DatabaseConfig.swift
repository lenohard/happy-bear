import Foundation

/// Configuration for the GRDB SQLite database
struct DatabaseConfig {
    /// Gets the default database URL
    static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.sqlite", isDirectory: false)
    }

    /// Gets the backup JSON URL (for rollback support)
    static var jsonBackupURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.json.backup", isDirectory: false)
    }

    /// Gets the legacy JSON URL
    static var legacyJSONURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }

    /// Ensures the application support directory exists
    static func ensureDirectoryExists() throws {
        let dir = defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
