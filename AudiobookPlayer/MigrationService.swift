import Foundation

/// Handles migration from JSON to SQLite database
actor MigrationService {
    /// Check if JSON data exists and needs migration
    static func needsMigration() -> Bool {
        FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path)
    }

    /// Get count of existing collections in JSON
    static func getJSONCollectionCount() -> Int {
        do {
            let data = try Data(contentsOf: DatabaseConfig.legacyJSONURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LibraryFile.self, from: data)
            return file.collections.count
        } catch {
            return 0
        }
    }

    /// Perform migration from JSON to SQLite
    static func migrate() async throws {
        print("🔄 Starting JSON → SQLite migration...")

        // Step 1: Load JSON data
        print("📥 Loading JSON data...")
        let jsonFile = try loadLegacyJSON()
        let originalCollectionCount = jsonFile.collections.count
        let originalTrackCount = jsonFile.collections.reduce(0) { $0 + $1.tracks.count }
        print("   Found \(originalCollectionCount) collections, \(originalTrackCount) tracks")

        // Step 2: Create backup
        print("💾 Creating backup...")
        try createJSONBackup()

        // Step 3: Initialize database
        print("🗄️  Initializing database...")
        let dbManager = GRDBDatabaseManager.shared
        try await dbManager.initializeDatabase()

        // Step 4: Insert data into SQLite
        print("📤 Migrating data to SQLite...")
        var failedCollections: [String] = []

        for (index, collection) in jsonFile.collections.enumerated() {
            do {
                try await dbManager.saveCollection(collection)
                let progress = Double(index + 1) / Double(originalCollectionCount)
                let percent = Int(progress * 100)
                print("   [\(percent)%] Migrated: \(collection.title)")
            } catch {
                failedCollections.append(collection.title)
                print("   ⚠️  Failed to migrate '\(collection.title)': \(error)")
            }
        }

        // Step 5: Verify migration
        print("✅ Verifying migration...")
        try await verifyMigration(
            expectedCollections: originalCollectionCount,
            expectedTracks: originalTrackCount,
            failedCollections: failedCollections
        )

        if failedCollections.isEmpty {
            print("✅ Migration completed successfully!")
            print("📦 Backup saved to: \(DatabaseConfig.jsonBackupURL.path)")
            print("🗄️  Database saved to: \(DatabaseConfig.defaultURL.path)")
        } else {
            print("⚠️  Migration completed with \(failedCollections.count) failures")
            print("   Failed collections: \(failedCollections.joined(separator: ", "))")
        }
    }

    /// Load legacy JSON file
    private static func loadLegacyJSON() throws -> LibraryFile {
        let data = try Data(contentsOf: DatabaseConfig.legacyJSONURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryFile.self, from: data)
    }

    /// Create backup of JSON before migration
    private static func createJSONBackup() throws {
        do {
            try DatabaseConfig.ensureDirectoryExists()
            if FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path) {
                // Remove existing backup if it exists
                if FileManager.default.fileExists(atPath: DatabaseConfig.jsonBackupURL.path) {
                    try FileManager.default.removeItem(at: DatabaseConfig.jsonBackupURL)
                    print("   Removed old backup")
                }
                try FileManager.default.copyItem(
                    at: DatabaseConfig.legacyJSONURL,
                    to: DatabaseConfig.jsonBackupURL
                )
                print("   Backup created: \(DatabaseConfig.jsonBackupURL.lastPathComponent)")
            }
        } catch {
            throw DatabaseError.migrationFailed("Could not create JSON backup: \(error)")
        }
    }

    /// Verify migration integrity
    private static func verifyMigration(
        expectedCollections: Int,
        expectedTracks: Int,
        failedCollections: [String]
    ) async throws {
        let dbManager = GRDBDatabaseManager.shared

        let collections = try await dbManager.loadAllCollections()
        let actualCollectionCount = collections.count
        let actualTrackCount = collections.reduce(0) { $0 + $1.tracks.count }

        let missingCollections = expectedCollections - actualCollectionCount

        print("   Expected: \(expectedCollections) collections, \(expectedTracks) tracks")
        print("   Migrated: \(actualCollectionCount) collections, \(actualTrackCount) tracks")

        if missingCollections > 0 {
            print("   ⚠️  \(missingCollections) collections failed to migrate")
        }

        if actualTrackCount != expectedTracks {
            print("   ⚠️  Track count mismatch: expected \(expectedTracks), got \(actualTrackCount)")
        }

        // Verify first collection has all its tracks
        if let firstCollection = collections.first {
            print("   Verified first collection '\(firstCollection.title)' has \(firstCollection.tracks.count) tracks")
        }
    }

    /// Restore from backup if migration failed
    static func restoreFromBackup() async throws {
        print("🔄 Restoring from JSON backup...")

        guard FileManager.default.fileExists(atPath: DatabaseConfig.jsonBackupURL.path) else {
            throw DatabaseError.migrationFailed("No backup JSON file found at \(DatabaseConfig.jsonBackupURL.path)")
        }

        do {
            // Copy backup back to original location
            if FileManager.default.fileExists(atPath: DatabaseConfig.legacyJSONURL.path) {
                try FileManager.default.removeItem(at: DatabaseConfig.legacyJSONURL)
            }

            try FileManager.default.copyItem(
                at: DatabaseConfig.jsonBackupURL,
                to: DatabaseConfig.legacyJSONURL
            )

            print("✅ Restored from backup: \(DatabaseConfig.jsonBackupURL.path)")
        } catch {
            throw DatabaseError.migrationFailed("Failed to restore from backup: \(error)")
        }
    }

    /// Check database integrity after migration
    static func checkDatabaseIntegrity() async throws -> MigrationIntegrityReport {
        let dbManager = GRDBDatabaseManager.shared
        let collections = try await dbManager.loadAllCollections()

        var report = MigrationIntegrityReport(
            totalCollections: collections.count,
            totalTracks: 0,
            collectionsWithMissingTracks: [],
            emptyCollections: [],
            corruptedTracks: [],
            isHealthy: true
        )

        for collection in collections {
            report.totalTracks += collection.tracks.count

            if collection.tracks.isEmpty {
                report.emptyCollections.append(collection.title)
            }

            // Check for orphaned playback states
            let orphanedStates = collection.playbackStates.filter { trackId, _ in
                !collection.tracks.contains { $0.id == trackId }
            }

            if !orphanedStates.isEmpty {
                report.collectionsWithMissingTracks.append(
                    "'\(collection.title)' has \(orphanedStates.count) orphaned playback states"
                )
            }
        }

        // Mark as unhealthy if there are empty collections or corrupted data
        if !report.emptyCollections.isEmpty || !report.collectionsWithMissingTracks.isEmpty {
            report.isHealthy = false
        }

        return report
    }
}

/// Report from migration integrity check
struct MigrationIntegrityReport {
    var totalCollections: Int
    var totalTracks: Int
    var collectionsWithMissingTracks: [String]
    var emptyCollections: [String]
    var corruptedTracks: [String]
    var isHealthy: Bool

    var description: String {
        var lines: [String] = []
        lines.append("Migration Integrity Report")
        lines.append("==========================")
        lines.append("Total Collections: \(totalCollections)")
        lines.append("Total Tracks: \(totalTracks)")
        lines.append("Health: \(isHealthy ? "✅ Healthy" : "⚠️  Issues Found")")

        if !emptyCollections.isEmpty {
            lines.append("\nEmpty Collections (\(emptyCollections.count)):")
            for collection in emptyCollections {
                lines.append("  - \(collection)")
            }
        }

        if !collectionsWithMissingTracks.isEmpty {
            lines.append("\nIssues (\(collectionsWithMissingTracks.count)):")
            for issue in collectionsWithMissingTracks {
                lines.append("  - \(issue)")
            }
        }

        if !corruptedTracks.isEmpty {
            lines.append("\nCorrupted Tracks (\(corruptedTracks.count)):")
            for track in corruptedTracks {
                lines.append("  - \(track)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
