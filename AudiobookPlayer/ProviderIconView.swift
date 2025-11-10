import SwiftUI

/// Displays a provider icon using deterministic colored initials.
/// Design principle: Simple, fast, and reliable without external dependencies.
struct ProviderIconView: View {
    let providerId: String
    let size: CGFloat = 24

    private var backgroundColor: Color {
        // Deterministic color based on provider name hash
        // Same provider always gets the same color across sessions
        let hash = providerId.hash
        let colors: [Color] = [
            .blue, .red, .green, .orange, .purple, .pink, .yellow, .cyan, .indigo
        ]
        return colors[abs(hash) % colors.count]
    }

    private var initials: String {
        // Extract 2-3 letter initials from provider name
        // Examples: "anthropic" → "AN", "openai" → "OP", "cohere/command" → "CO"
        let parts = providerId.split(separator: "/").first ?? Substring(providerId)
        return String(parts.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.8))

            Text(initials)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("\(providerId) provider"))
    }
}

#Preview {
    HStack(spacing: 12) {
        ProviderIconView(providerId: "anthropic")
        ProviderIconView(providerId: "openai")
        ProviderIconView(providerId: "google")
        ProviderIconView(providerId: "unknown-provider")
    }
    .padding()
}
