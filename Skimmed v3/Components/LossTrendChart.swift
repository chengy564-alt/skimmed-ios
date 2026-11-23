import SwiftUI

/// A quiet-luxury loss-trend chart — a soft amber area under a thin line,
/// with a glowing dot on the latest month and sparse month labels. Draws
/// itself in left-to-right when `revealed` flips (static under Reduce Motion).
///
/// Replaces the old bar-grid + heat-square pair, which rendered the same
/// monthly-loss data twice. Pure geometry, no external chart dependency.
struct LossTrendChart: View {
    let points: [Double]
    let labels: [String]
    let maxValue: Double
    let accent: Color
    let revealed: Bool
    let reduceMotion: Bool

    private let labelHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let plotH = max(1, geo.size.height - labelHeight)
            let coords = coordinates(in: CGSize(width: geo.size.width, height: plotH))

            ZStack(alignment: .topLeading) {
                // Baseline hairline.
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .offset(y: plotH - 0.5)

                if coords.count >= 2 {
                    // Soft amber area fill.
                    areaPath(coords, height: plotH)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.32), accent.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // The trend line.
                    linePath(coords)
                        .stroke(
                            LinearGradient(
                                colors: [accent.opacity(0.9), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                }

                // Glowing dot on the latest month.
                if let last = coords.last {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                        .shadow(color: accent.opacity(0.7), radius: 6)
                        .position(x: last.x, y: last.y)
                }
            }
            // Reveal left-to-right by masking a growing rectangle.
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(width: (revealed || reduceMotion) ? geo.size.width : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: revealed)
            }
            .overlay(alignment: .bottom) {
                monthLabels(width: geo.size.width)
                    .frame(height: labelHeight)
            }
        }
    }

    // MARK: - Geometry

    private func coordinates(in size: CGSize) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        let denom = maxValue > 0 ? maxValue : 1
        let stepX = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
        return points.enumerated().map { i, value in
            let x = points.count > 1 ? CGFloat(i) * stepX : size.width / 2
            let y = size.height - CGFloat(value / denom) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    /// Smooth line through the points using mid-point quadratic curves.
    private func linePath(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            for i in 1..<pts.count {
                let prev = pts[i - 1]
                let curr = pts[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                p.addQuadCurve(to: mid, control: prev)
                p.addQuadCurve(to: curr, control: curr)
            }
        }
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var path = linePath(pts)
        guard let first = pts.first, let last = pts.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }

    // MARK: - Labels

    private func monthLabels(width: CGFloat) -> some View {
        // Show at most ~6 labels evenly, initials only, to stay uncluttered.
        let count = labels.count
        let stride = max(1, Int(ceil(Double(count) / 6)))
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Text(i % stride == 0 ? String(label.prefix(1)) : " ")
                    .font(.app(8, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
