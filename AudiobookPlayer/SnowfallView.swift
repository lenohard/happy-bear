import SwiftUI

struct SnowfallView: View {
    @State private var snowflakes: [Snowflake] = []
    
    struct Snowflake: Identifiable {
        let id = UUID()
        var initialX: CGFloat
        var initialY: CGFloat
        let size: CGFloat
        let speed: CGFloat
        let opacity: Double
        let swaySpeed: Double
        let swayAmplitude: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    
                    for flake in snowflakes {
                        // Continuous fall: y = (initialY + speed * time) % (height + buffer)
                        let fallDistance = flake.speed * 60 * time // Speed multiplier
                        let totalHeight = size.height + 50
                        let currentY = (flake.initialY + fallDistance).truncatingRemainder(dividingBy: totalHeight) - 20
                        
                        // Gentle sway: x = initialX + sin(time * swaySpeed) * amplitude
                        let sway = sin(time * flake.swaySpeed) * flake.swayAmplitude
                        let currentX = flake.initialX + sway
                        
                        let rect = CGRect(x: currentX, y: currentY, width: flake.size, height: flake.size)
                        
                        // Draw soft circle
                        context.opacity = flake.opacity
                        context.fill(Path(ellipseIn: rect), with: .color(.white))
                    }
                }
            }
        }
        .onAppear {
            initializeSnowflakes()
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func initializeSnowflakes() {
        // Create a dense, varied field of snow
        snowflakes = (0..<80).map { _ in
            Snowflake(
                initialX: CGFloat.random(in: 0...1000), // Wide range to cover rotation/sway
                initialY: CGFloat.random(in: 0...1000),
                size: CGFloat.random(in: 10...24), // Larger flakes
                speed: CGFloat.random(in: 0.5...1.5),
                opacity: Double.random(in: 0.2...0.7),
                swaySpeed: Double.random(in: 1.0...3.0),
                swayAmplitude: CGFloat.random(in: 5...20)
            )
        }
    }
}
