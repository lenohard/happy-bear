import Foundation

struct AppInfo {
    struct ChangelogEntry: Identifiable {
        let id = UUID()
        let date: String
        let description: String
    }

    static let githubURL = URL(string: "https://github.com/lenohard/happy-bear")!
    static let versionFallback = "1.0.0"
    static let changelog: [ChangelogEntry] = [
        .init(date: "2025-11-28", description: "About page lists version, changelog, and GitHub link.") ,
        .init(date: "2025-11-15", description: "Keychain sharing capability added for unsigned Mac Catalyst DMG releases."),
        .init(date: "2025-11-10", description: "Simplified Soniox transcription path by removing audio conversion steps."),
    ]

    static var currentVersionDisplay: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version = shortVersion, let build = buildNumber {
            return "\(version) (\(build))"
        }
        if let version = shortVersion {
            return version
        }
        return versionFallback
    }

    static var buildTimestampDisplay: String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path)
        if let date = attributes?[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: date)
        }
        return nil
    }
}
