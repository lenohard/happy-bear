import SwiftUI

/// Displays a provider icon with fallback to initials
struct ProviderIconView: View {
    let providerId: String
    let size: CGFloat = 24

    private var backgroundColor: Color {
        // Deterministic color based on provider name
        let hash = providerId.hash
        let colors: [Color] = [
            .blue, .red, .green, .orange, .purple, .pink, .yellow, .cyan, .indigo
        ]
        return colors[abs(hash) % colors.count]
    }

    private var initials: String {
        let parts = providerId.split(separator: "/").first ?? Substring(providerId)
        return String(parts.prefix(2)).uppercased()
    }

    private var logoURL: URL {
        URL(string: "https://models.dev/logos/\(providerId).svg")!
    }

    var body: some View {
        AsyncImage(url: logoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            case .failure, .empty:
                // Show initials fallback
                ZStack {
                    Circle()
                        .fill(backgroundColor.opacity(0.8))

                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: size, height: size)
            @unknown default:
                EmptyView()
            }
        }
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
