import Foundation

/// Handles migration from JSON persistence to GRDB SQLite persistence
actor MigrationCoordinator {
    /// Check if JSON data exists and needs migration
    static func needsMigration() -> Bool {
        FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path)
    }

    /// Perform migration from JSON to SQLite
    static func migrate(from jsonPersistence: LibraryPersistence) async throws {
        let legacyFile = try await jsonPersistence.load()

        // Create backup first
        do {
            try DatabaseConfig.ensureDirectoryExists()
            if FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path) {
                try FileManager.default.copyItem(
                    at: DatabaseConfig.legacyJSONURL,
                    to: DatabaseConfig.jsonBackupURL
                )
            }
        } catch {
            throw DatabaseError.migrationFailed("Could not create JSON backup: \(error)")
        }

        // Perform actual migration
        let dbManager = DatabaseManager.shared
        try await dbManager.initializeDatabase()

        do {
            // Insert all collections into database
            for collection in legacyFile.collections {
                try await dbManager.saveCollection(collection)
            }

            print("✅ Migration completed successfully")
            print("📦 Backup saved to: \(DatabaseConfig.jsonBackupURL.path)")

            // Cleanup: Remove legacy JSON file after successful migration
            do {
                if FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path) {
                    try FileManager.default.removeItem(at: DatabaseConfig.legacyJSONURL)
                    print("🗑️  Removed legacy JSON file: \(DatabaseConfig.legacyJSONURL.path)")
                }
            } catch {
                // Log but don't fail the migration if cleanup fails
                print("⚠️  Warning: Could not remove legacy JSON file: \(error)")
            }
        } catch {
            throw DatabaseError.migrationFailed("Failed to migrate collections: \(error)")
        }
    }

    /// Restore from JSON backup if migration failed
    static func restoreFromBackup(to jsonPersistence: LibraryPersistence) async throws {
        guard FileManager.default.fileExists(atPath: DatabaseConfig.jsonBackupURL.path) else {
            throw DatabaseError.migrationFailed("No backup JSON file found")
        }

        do {
            let backupData = try Data(contentsOf: DatabaseConfig.jsonBackupURL)
            try Data(contentsOf: DatabaseConfig.jsonBackupURL).write(
                to: DatabaseConfig.legacyJSONURL,
                options: .atomic
            )
            print("✅ Restored from backup: \(DatabaseConfig.jsonBackupURL.path)")
        } catch {
            throw DatabaseError.migrationFailed("Failed to restore from backup: \(error)")
        }
    }

    /// Check database integrity after migration
    static func verifyMigrationIntegrity(
        originalCollectionCount: Int,
        originalTrackCount: Int
    ) async throws {
        // Verify that migrated data matches original counts
        // This will be implemented after GRDB integration
    }
}
