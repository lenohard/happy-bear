import SwiftUI

/// Reusable control for toggling a track's favorite state with accessible feedback.
struct FavoriteToggleButton: View {
    enum DisplayStyle {
        case icon
        case bordered
    }
    
    let isFavorite: Bool
    let style: DisplayStyle
    let action: () -> Void
    
    init(isFavorite: Bool, style: DisplayStyle = .icon, action: @escaping () -> Void) {
        self.isFavorite = isFavorite
        self.style = style
        self.action = action
    }
    
    var body: some View {
        styledButton
            .tint(isFavorite ? .red : .accentColor)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(isFavorite ? [.isSelected] : [])
    }
    
    @ViewBuilder
    private var styledButton: some View {
        switch style {
        case .icon:
            Button(action: action) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? .red : .secondary)
            }
            .buttonStyle(.plain)
        case .bordered:
            Button(action: action) {
                Label(
                    isFavorite
                    ? NSLocalizedString("remove_from_favorites", comment: "Remove from favorites button")
                    : NSLocalizedString("add_to_favorites", comment: "Add to favorites button"),
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    private var accessibilityLabel: String {
        isFavorite
        ? NSLocalizedString("remove_from_favorites", comment: "Remove from favorites button")
        : NSLocalizedString("add_to_favorites", comment: "Add to favorites button")
    }
}
