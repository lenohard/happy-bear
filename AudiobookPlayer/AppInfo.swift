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
        .init(date: "2025-12-08", description: "支持导入RSS创建合集"),
        .init(date: "2025-12-08", description: "生成摘要总是用中文"),
        .init(date: "2025-12-05", description: "Smart auto-focus in transcript viewer with manual scroll detection."),
        .init(date: "2025-12-05", description: "Enhanced TTS robustness, background job handling and UI polish."),
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
