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
        .init(date: "2025-12-05", description: "Floating bubble now stays above sheets with proper touch handling."),
        .init(date: "2025-12-05", description: "Refined transcript segmentation to handle decimals and prevent overly short segments."),
        .init(date: "2025-12-05", description: "Smart auto-focus in transcript viewer with manual scroll detection."),
        .init(date: "2025-12-05", description: "Enhanced TTS robustness, background job handling and UI polish."),
        .init(date: "2025-12-05", description: "Preload playback collections for instant listening history display."),
        .init(date: "2025-12-05", description: "Fixed listening history and playback progress loss after app relaunch."),
        .init(date: "2025-12-05", description: "Added collection import service and refresh handling for Baidu Netdisk."),
        .init(date: "2025-12-05", description: "Fixed ebook date parsing errors using timeIntervalSinceReferenceDate."),
        .init(date: "2025-12-05", description: "Optimized CollectionDetailView scroll performance by removing visibleTrackIndices."),
        .init(date: "2025-11-28", description: "About page lists version, changelog, and GitHub link."),
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
