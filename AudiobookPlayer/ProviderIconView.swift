import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ProviderIconView: View {
    let providerId: String
    let size: CGFloat = 24

    private var assetName: String {
        // Replace characters that are not friendly for asset names
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = providerId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce("") { $0 + String($1) }
        return sanitized
    }

    private var assetImage: Image? {
        #if canImport(UIKit)
        if UIImage(named: assetName) != nil {
            return Image(assetName)
        }
        #elseif canImport(AppKit)
        if NSImage(named: assetName) != nil {
            return Image(assetName)
        }
        #endif
        return nil
    }

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
        Group {
            if let assetImage {
                assetImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            } else {
                ZStack {
                    Circle()
                        .fill(backgroundColor.opacity(0.8))

                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: size, height: size)
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
