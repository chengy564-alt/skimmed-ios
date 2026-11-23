import SwiftUI

// Surface/glass modifiers live in Theme.swift (`surfaceCard`, `glass`).
// This file holds small shared shapes and surface effects.

/// Horizontal line; stroked with a dashed style for the receipt dividers on
/// onboarding Screen 1.
struct LineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// One-shot diagonal shimmer band that sweeps across its bounds — the glint
/// used for unlocks and the Reveal number settle. Runs once per appearance;
/// callers clip it to their card shape.
struct LightSweep: View {
    @State private var progress: CGFloat = -0.5

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.16), Color.white.opacity(0.05), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.55)
            .rotationEffect(.degrees(16))
            .offset(x: progress * geo.size.width * 1.8)
            .blendMode(.plusLighter)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8)) { progress = 1.0 }
            }
        }
        .allowsHitTesting(false)
    }
}
