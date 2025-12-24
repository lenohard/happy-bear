import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case christmas

    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system: return NSLocalizedString("theme_system", value: "System", comment: "System theme")
        case .light: return NSLocalizedString("theme_light", value: "Light", comment: "Light theme")
        case .dark: return NSLocalizedString("theme_dark", value: "Dark", comment: "Dark theme")
        case .christmas: return NSLocalizedString("theme_christmas", value: "Christmas", comment: "Christmas theme")
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "gear"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .christmas: return "snowflake"
        }
    }
}

struct ThemeColors {
    let primary: Color
    let secondary: Color
    let background: Color
    let secondaryBackground: Color
    let accent: Color
    let text: Color
    let secondaryText: Color
    
    // Christmas specific
    let festiveRed: Color
    let festiveGreen: Color
    let festiveGold: Color
    let isFestive: Bool
}

class ThemeManager: ObservableObject {
    @AppStorage("selectedTheme") var currentTheme: AppTheme = .system {
        didSet {
            // When theme changes, mark that user has explicitly set a theme
            if oldValue != currentTheme {
                UserDefaults.standard.set(true, forKey: "hasUserSetTheme")
            }
        }
    }

    @Published var showFestiveDecorations: Bool = true {
        didSet {
            UserDefaults.standard.set(showFestiveDecorations, forKey: "showFestiveDecorations")
        }
    }

    init() {
        self.showFestiveDecorations = UserDefaults.standard.object(forKey: "showFestiveDecorations") as? Bool ?? true
        checkSeasonalTheme()
    }

    private func checkSeasonalTheme() {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)

        // Auto-enable Christmas theme Dec 20-26 if no user preference
        if month == 12 && (20...26).contains(day) {
            if !UserDefaults.standard.bool(forKey: "hasUserSetTheme") {
                currentTheme = .christmas
            }
        }
    }

    var colors: ThemeColors {
        switch currentTheme {
        case .christmas:
            return ThemeColors(
                primary: Color(hex: "D42426") ?? .red, // Christmas Red
                secondary: Color(hex: "165B33") ?? .green, // Christmas Green
                background: Color(hex: "F8F5F2") ?? Color(uiColor: .systemBackground), // Snow White/Cream
                secondaryBackground: Color(hex: "E8F3E8") ?? Color(uiColor: .secondarySystemBackground), // Light Green Tint
                accent: Color(hex: "F8B229") ?? .yellow, // Gold
                text: .black,
                secondaryText: .gray,
                festiveRed: Color(hex: "D42426") ?? .red,
                festiveGreen: Color(hex: "165B33") ?? .green,
                festiveGold: Color(hex: "F8B229") ?? .yellow,
                isFestive: true
            )
        case .light:
            return ThemeColors(
                primary: .blue,
                secondary: .green,
                background: Color(uiColor: .systemBackground),
                secondaryBackground: Color(uiColor: .secondarySystemBackground),
                accent: .blue,
                text: .primary,
                secondaryText: .secondary,
                festiveRed: .red,
                festiveGreen: .green,
                festiveGold: .yellow,
                isFestive: false
            )
        case .dark:
            return ThemeColors(
                primary: .blue,
                secondary: .green,
                background: Color(uiColor: .systemBackground),
                secondaryBackground: Color(uiColor: .secondarySystemBackground),
                accent: .blue,
                text: .primary,
                secondaryText: .secondary,
                festiveRed: .red,
                festiveGreen: .green,
                festiveGold: .yellow,
                isFestive: false
            )
        case .system:
            return ThemeColors(
                primary: .accentColor,
                secondary: .green,
                background: Color(uiColor: .systemBackground),
                secondaryBackground: Color(uiColor: .secondarySystemBackground),
                accent: .accentColor,
                text: .primary,
                secondaryText: .secondary,
                festiveRed: .red,
                festiveGreen: .green,
                festiveGold: .yellow,
                isFestive: false
            )
        }
    }
    
    var colorScheme: ColorScheme? {
        switch currentTheme {
        case .light, .christmas: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
