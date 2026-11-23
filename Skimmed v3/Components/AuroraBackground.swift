import SwiftUI

/// Decorative warm "aurora" for Home's empty (no-trip) state — 4 very soft,
/// heavily-blurred amber/orange light ribbons that drift and breathe slowly,
/// reading as luminous liquid-glass light over the dark backdrop.
///
/// Purely ornamental: never hit-tests, carries no data. Motion is deterministic
/// (per-index phase, ~30fps via `TimelineView`) so it's calm and repeatable, not
/// noisy. Honors Reduce Motion by rendering a static, tastefully-placed glow.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each ribbon's resting placement + tint + drift character. Positions are
    /// unit fractions of the canvas so it scales to any size.
    private struct Ribbon {
        let unitX: CGFloat
        let unitY: CGFloat
        let scale: CGFloat        // fraction of the longer edge
        let color: Color
        let opacity: Double
        let driftX: CGFloat       // horizontal sway, in unit fractions
        let driftY: CGFloat       // vertical sway, in unit fractions
        let period: Double        // seconds for one full breathing cycle
        let phase: Double         // deterministic per-ribbon offset
    }

    private let ribbons: [Ribbon] = [
        Ribbon(unitX: 0.24, unitY: 0.20, scale: 1.15, color: Theme.accentHot,
               opacity: 0.34, driftX: 0.05, driftY: 0.035, period: 26, phase: 0.0),
        Ribbon(unitX: 0.82, unitY: 0.34, scale: 0.95, color: Theme.accent,
               opacity: 0.30, driftX: 0.045, driftY: 0.05, period: 31, phase: 1.7),
        Ribbon(unitX: 0.60, unitY: 0.78, scale: 1.30, color: Theme.loss,
               opacity: 0.20, driftX: 0.06, driftY: 0.03, period: 37, phase: 3.1),
        Ribbon(unitX: 0.14, unitY: 0.66, scale: 0.80, color: Theme.accent,
               opacity: 0.24, driftX: 0.035, driftY: 0.045, period: 22, phase: 4.6),
    ]

    var body: some View {
        GeometryReader { geo in
            let edge = max(geo.size.width, geo.size.height)
            let blur = edge * 0.13

            if reduceMotion {
                Canvas { context, _ in
                    for ribbon in ribbons {
                        draw(ribbon, at: 0, in: geo.size, context: context)
                    }
                }
                .blur(radius: blur)
                .blendMode(.plusLighter)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in
                        for ribbon in ribbons {
                            draw(ribbon, at: t, in: geo.size, context: context)
                        }
                    }
                    .blur(radius: blur)
                    .blendMode(.plusLighter)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Paints one ribbon as a soft radial-gradient ellipse, drifting + breathing
    /// on two slow sines so no two ribbons ever move in lockstep.
    private func draw(_ ribbon: Ribbon, at t: Double, in size: CGSize, context: GraphicsContext) {
        let edge = max(size.width, size.height)
        let angle = (t / ribbon.period) * 2 * .pi + ribbon.phase
        let breathe = 1 + 0.10 * sin(angle * 0.85)

        let cx = (ribbon.unitX + ribbon.driftX * CGFloat(sin(angle))) * size.width
        let cy = (ribbon.unitY + ribbon.driftY * CGFloat(cos(angle * 0.7))) * size.height

        let radius = edge * ribbon.scale * 0.5 * breathe
        let rect = CGRect(
            x: cx - radius, y: cy - radius * 0.82,
            width: radius * 2, height: radius * 1.64
        )

        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [
                ribbon.color.opacity(ribbon.opacity),
                ribbon.color.opacity(ribbon.opacity * 0.35),
                .clear,
            ]),
            center: CGPoint(x: cx, y: cy),
            startRadius: 0,
            endRadius: radius
        )
        context.fill(Ellipse().path(in: rect), with: shading)
    }
}
