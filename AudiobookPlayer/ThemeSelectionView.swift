import SwiftUI

struct ThemeSelectionView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        List {
            Section {
                ForEach(AppTheme.allCases) { theme in
                    HStack {
                        Label {
                            Text(theme.displayName)
                        } icon: {
                            Image(systemName: theme.icon)
                                .foregroundStyle(iconColor(for: theme))
                        }
                        
                        Spacer()
                        
                        if themeManager.currentTheme == theme {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            themeManager.currentTheme = theme
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("appearance_header", value: "Appearance", comment: "Appearance section header"))
            } footer: {
                if themeManager.currentTheme == .christmas {
                    Text(NSLocalizedString("christmas_theme_footer", value: "Enjoy the festive spirit with our special Christmas theme! 🎄", comment: "Christmas theme footer"))
                }
            }

            if themeManager.currentTheme == .christmas {
                Section {
                    Toggle("Show Festive Decorations", isOn: $themeManager.showFestiveDecorations)
                } footer: {
                    Text("Enable animated snowfall and other festive decorations.")
                }
            }
        }
        .navigationTitle(NSLocalizedString("theme_title", value: "Theme", comment: "Theme view title"))
    }
    
    private func iconColor(for theme: AppTheme) -> Color {
        switch theme {
        case .christmas: return .red
        case .light: return .orange
        case .dark: return .purple
        case .system: return .gray
        }
    }
}
