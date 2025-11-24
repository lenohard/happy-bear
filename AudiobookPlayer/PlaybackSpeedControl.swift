import SwiftUI

struct PlaybackSpeedControl: View {
    @Binding var playbackRate: Double
    let presets: [Double]
    
    @State private var scrollID: Double?
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                // Add spacing at the top to center the first item
                Color.clear
                    .frame(height: 20)
                
                ForEach(presets, id: \.self) { rate in
                    SpeedItem(
                        rate: rate,
                        isSelected: abs(playbackRate - rate) < 0.01
                    )
                    .id(rate)
                    .containerRelativeFrame(.vertical, count: 3, spacing: 0)
                    .scrollTransition { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1.0 : 0.3)
                            .scaleEffect(phase.isIdentity ? 1.2 : 0.8)
                            .blur(radius: phase.isIdentity ? 0 : 1)
                    }
                    .onTapGesture {
                        withAnimation(.snappy) {
                            playbackRate = rate
                            scrollID = rate
                        }
                    }
                }
                
                // Add spacing at the bottom to center the last item
                Color.clear
                    .frame(height: 20)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollID, anchor: .center)
        .frame(width: 45, height: 90)
        .onChange(of: scrollID) { oldValue, newValue in
            if let newValue {
                if abs(playbackRate - newValue) > 0.01 {
                    playbackRate = newValue
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
            }
        }
        .onAppear {
            // Find closest preset to current rate
            let closest = presets.min(by: { abs($0 - playbackRate) < abs($1 - playbackRate) })
            scrollID = closest
        }
    }
    
    private struct SpeedItem: View {
        let rate: Double
        let isSelected: Bool
        
        var body: some View {
            Text(formattedSpeed(rate))
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 45, height: 26)
        }
        
        private func formattedSpeed(_ rate: Double) -> String {
            // Remove trailing zeros for integers, e.g. "1.0" -> "1x", "1.5" -> "1.5x"
            let formatted = rate.formatted(.number.precision(.fractionLength(0...1)))
            return "\(formatted)x"
        }
    }
}

#Preview {
    PlaybackSpeedControl(
        playbackRate: .constant(1.0),
        presets: [0.2, 0.5, 0.8, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
    )
}
