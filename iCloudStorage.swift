import Foundation

/// Manages iCloud container URL resolution with fallback to local ApplicationSupport.
struct iCloudStorage {
    /// Returns the iCloud container Documents URL, or nil if iCloud is unavailable.
    static func containerURL() -> URL? {
        return FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Root URL for all app data (DB + covers).
    /// Uses iCloud container when available, falls back to ApplicationSupport.
    static var rootURL: URL {
        if let icloud = containerURL() {
            return icloud
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudiobookPlayer", isDirectory: true)
    }

    /// Whether iCloud storage is currently available.
    static var isAvailable: Bool {
        return containerURL() != nil
    }
}
