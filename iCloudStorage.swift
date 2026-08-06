import Foundation

/// Manages iCloud container URL resolution with fallback to local ApplicationSupport.
struct iCloudStorage {
    /// Known iCloud container identifiers for this app (iOS + Catalyst).
    /// The folder name in ~/Library/Mobile Documents/ replaces `.` with `~`.
    private static let containerIdentifiers = [
        "iCloud.com.senaca.audiobookplayer",
        "iCloud.com.tortugapower.audiobookplayer",
    ]

    /// Returns the iCloud container Documents URL, or nil if iCloud is unavailable.
    static func containerURL() -> URL? {
        // Primary: use ubiquity container API (requires entitlements)
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true) {
            return ubiquityURL
        }
        // Fallback (Mac Catalyst): read iCloud Drive local sync path directly.
        // Catalyst is os(iOS), not os(macOS). Without iCloud entitlements the
        // ubiquity API returns nil; iCloud Drive still syncs files locally.
        #if targetEnvironment(macCatalyst)
        return findLocalCloudDocsContainer()
        #else
        return nil
        #endif
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

    #if targetEnvironment(macCatalyst)
    /// Searches ~/Library/Mobile Documents/ for a matching iCloud container.
    /// iCloud Drive maps `iCloud.com.foo.bar` → `iCloud~com~foo~bar`.
    private static func findLocalCloudDocsContainer() -> URL? {
        let mobileDocs = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let fm = FileManager.default

        // Check each known identifier
        for identifier in containerIdentifiers {
            let folderName = identifier.replacingOccurrences(of: ".", with: "~")
            let containerURL = mobileDocs.appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
            if fm.fileExists(atPath: containerURL.path) {
                return containerURL
            }
        }
        return nil
    }
    #endif
}
