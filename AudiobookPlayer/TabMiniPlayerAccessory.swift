import SwiftUI

/// Places the mini-player above the tab bar (Apple Music style) without covering tabs.
private enum TabMiniPlayerMetrics {
    static let barHeight: CGFloat = 52
    static let gapAboveTabBar: CGFloat = 8
    /// UITabBar standard height (home indicator is separate).
    static let tabBarHeight: CGFloat = 49
}

extension View {
    @ViewBuilder
    func tabMiniPlayerAccessory<Accessory: View>(
        isEnabled: Bool,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled, content: accessory)
        } else if #available(iOS 26.0, *) {
            tabViewBottomAccessory {
                if isEnabled {
                    accessory()
                }
            }
        } else {
            legacyTabMiniPlayerAccessory(isEnabled: isEnabled, accessory: accessory)
        }
    }

    @ViewBuilder
    private func legacyTabMiniPlayerAccessory<Accessory: View>(
        isEnabled: Bool,
        accessory: @escaping () -> Accessory
    ) -> some View {
        let reserveHeight = TabMiniPlayerMetrics.barHeight + TabMiniPlayerMetrics.gapAboveTabBar
        let overlayBottom = TabMiniPlayerMetrics.tabBarHeight + TabMiniPlayerMetrics.gapAboveTabBar

        safeAreaInset(edge: .bottom, spacing: 0) {
            if isEnabled {
                Color.clear.frame(height: reserveHeight)
            }
        }
        .overlay(alignment: .bottom) {
            if isEnabled {
                accessory()
                    .padding(.bottom, overlayBottom)
            }
        }
    }
}
