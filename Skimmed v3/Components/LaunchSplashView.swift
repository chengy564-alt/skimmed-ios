import SwiftUI
import UIKit

/// Cold-launch splash — the eclipse image revealed in place.
///
/// Every frame is the bundled artwork's own pixels; the animation only
/// uncovers them with soft masks (nothing is redrawn, so the finished frame
/// is the reference image exactly). Sequence, matching the approved preview:
///   0.00–1.10  rim closes left → right (trimmed arc mask riding the limb)
///   1.05       dot breathes in
///   1.18–1.76  trail draws out to the star
///   1.72       star blooms — soft haptic
///   1.20–2.20  the image's faintest residuals settle in underneath
///   2.55–3.25  the whole scene exhales into the app (fade + slight zoom)
///
/// Plays on cold launch only (it lives on process start in `SkimmedApp`;
/// returning from background never re-creates it). Reduce Motion collapses
/// the reveal to a plain cross-fade.
struct LaunchSplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Image-space geometry (853 × 1844), measured from the artwork.
    private static let imageSize = CGSize(width: 853, height: 1844)

    @State private var rimProgress: CGFloat = 0
    @State private var trailProgress: CGFloat = 0
    @State private var dotVisible = false
    @State private var starVisible = false
    @State private var baseVisible = false
    @State private var sceneOpacity: Double = 1
    @State private var sceneScale: CGFloat = 1
    @State private var sceneBlur: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let scale = max(geo.size.width / Self.imageSize.width,
                            geo.size.height / Self.imageSize.height)

            ZStack {
                Color.black

                ZStack {
                    // Residuals — the barely-visible lower limb etc.
                    splashImage
                        .opacity(baseVisible ? 1 : 0)

                    // Rim, closing left → right.
                    splashImage
                        .mask {
                            RimArcShape()
                                .trim(from: 0, to: rimProgress)
                                .stroke(style: StrokeStyle(lineWidth: 150, lineCap: .butt))
                                .blur(radius: 16)
                        }

                    // Dot.
                    splashImage
                        .mask {
                            Circle()
                                .frame(width: 124, height: 124)
                                .position(x: 389, y: 996)
                                .blur(radius: 10)
                        }
                        .opacity(dotVisible ? 1 : 0)

                    // Trail.
                    splashImage
                        .mask {
                            TrailShape()
                                .trim(from: 0, to: trailProgress)
                                .stroke(style: StrokeStyle(lineWidth: 52, lineCap: .round))
                                .blur(radius: 10)
                        }

                    // Star.
                    splashImage
                        .mask {
                            Circle()
                                .frame(width: 172, height: 172)
                                .scaleEffect(starVisible ? 1 : 0.55)
                                .position(x: 701, y: 895)
                                .blur(radius: 16)
                        }
                        .opacity(starVisible ? 1 : 0)
                }
                .frame(width: Self.imageSize.width, height: Self.imageSize.height)
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .opacity(sceneOpacity)
            .scaleEffect(sceneScale)
            .blur(radius: sceneBlur)
            .ignoresSafeArea()
        }
        .task { await run() }
    }

    /// Loaded from the loose bundle resource (not an asset catalog, so
    /// `Image(_:bundle:)` can't find it — `UIImage(contentsOfFile:)` can).
    private static let artwork: UIImage? = {
        guard let path = Bundle.main.path(forResource: "eclipse-splash", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }()

    @ViewBuilder
    private var splashImage: some View {
        if let artwork = Self.artwork {
            Image(uiImage: artwork)
                .resizable()
                .frame(width: Self.imageSize.width, height: Self.imageSize.height)
        } else {
            Color.black
        }
    }

    private func run() async {
        if reduceMotion {
            // Plain cross-fade: full image in, hold, out.
            baseVisible = true
            rimProgress = 1; trailProgress = 1
            dotVisible = true; starVisible = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.5)) { sceneOpacity = 0 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            onFinished()
            return
        }

        // Rim: 0 → 1.1s.
        withAnimation(.timingCurve(0.35, 0.08, 0.24, 1, duration: 1.1)) {
            rimProgress = 1
        }
        // Dot at 1.05s.
        try? await Task.sleep(nanoseconds: 1_050_000_000)
        withAnimation(.easeOut(duration: 0.35)) { dotVisible = true }

        // Trail at 1.18s (0.13 after dot).
        try? await Task.sleep(nanoseconds: 130_000_000)
        withAnimation(.timingCurve(0.42, 0.05, 0.25, 1, duration: 0.58)) {
            trailProgress = 1
        }
        withAnimation(.easeInOut(duration: 1.0).delay(0.02)) { baseVisible = true }

        // Star at 1.72s.
        try? await Task.sleep(nanoseconds: 540_000_000)
        withAnimation(.timingCurve(0.25, 0.1, 0.2, 1, duration: 0.55)) {
            starVisible = true
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)

        // Hold the finished frame, then exhale into the app.
        try? await Task.sleep(nanoseconds: 830_000_000) // → 2.55s
        withAnimation(.timingCurve(0.4, 0.05, 0.6, 1, duration: 0.7)) {
            sceneOpacity = 0
            sceneScale = 1.1
            sceneBlur = 5
        }
        try? await Task.sleep(nanoseconds: 720_000_000)
        onFinished()
    }
}

// MARK: - Mask shapes (image coordinate space, 853 × 1844)

/// The disc's limb: center (411, 1021) r 246, from the left horizon
/// (~169°) over the top to the upper right (~323°). Sampled as a polyline —
/// `trim` handles the left→right close.
private struct RimArcShape: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: 411, y: 1021)
        let radius: CGFloat = 246
        let start = 168.9 * .pi / 180
        let end = 322.9 * .pi / 180
        let steps = 72
        for i in 0...steps {
            let a = start + (end - start) * CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// The trail from the dot's edge to the star, matching the artwork's curve.
private struct TrailShape: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 412, y: 996))
        path.addLine(to: CGPoint(x: 498, y: 996))
        path.addCurve(to: CGPoint(x: 612, y: 936),
                      control1: CGPoint(x: 548, y: 996),
                      control2: CGPoint(x: 572, y: 977))
        path.addCurve(to: CGPoint(x: 674, y: 896),
                      control1: CGPoint(x: 634, y: 913),
                      control2: CGPoint(x: 652, y: 901))
        return path
    }
}
