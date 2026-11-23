import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// SwiftUI has no built-in hex initializer; this parses "#RRGGBB" (or "RRGGBB").
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Palette (mirrors globals.css / tailwind.config.ts)

enum Theme {
    static let bg = Color(hex: "#120703")
    static let surface = Color(hex: "#241007")
    static let surface2 = Color(hex: "#32180B")
    static let surface3 = Color(hex: "#45210F")
    static let accent = Color(hex: "#F26A1B")
    static let accentHot = Color(hex: "#FF7A22")
    static let loss = Color(hex: "#FF5C38")
    static let cream = Color(hex: "#FFF1E7")
    static let muted = Color(hex: "#B88B70")
    static let good = Color(hex: "#4ADE80")
    static let bad = Color(hex: "#FF6B5C")
    /// Dark ink used on top of amber fills (buttons, active nav circle).
    static let onAccent = Color(hex: "#1C1208")

    /// The Reveal number gradient — CSS: linear-gradient(135deg, #FFB26B, #F97316, #FF5C38)
    static let lossGradient = LinearGradient(
        colors: [Color(hex: "#FFD0A1"), Color(hex: "#FF7A22"), Color(hex: "#F04F1A")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Amber primary-button gradient — CSS: linear-gradient(180deg, accent-hot, accent)
    static let buttonGradient = LinearGradient(
        colors: [accentHot, accent],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - App Font (Avenir Next Rounded)
// PostScript names for Avenir Next Rounded. This is a system font on macOS.
// For iOS, add the font files to the project and declare them in Info.plist (UIAppFonts).

extension Font {
    static func app(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // San Francisco (SF Pro), the system font, at the requested weight.
        // (This helper previously asked for "AvenirNextRounded-*", which isn't
        // an iOS font, so it silently fell back to the system font AT REGULAR
        // WEIGHT — headings never got their intended heft. Requesting the
        // system font directly keeps the same SF Pro look but honors the weight.)
        .system(size: size, weight: weight)
    }
}

// MARK: - Surface + Liquid Glass materials

extension View {
    /// Opaque card surface: #241D18 fill, 22pt continuous corners,
    /// 1px white-0.07 stroke, soft drop shadow.
    func surfaceCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [Theme.surface2.opacity(0.98), Theme.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.12), .clear],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 12)
    }

    /// Liquid Glass effect applied within the given shape.
    func glass<S: Shape>(in shape: S) -> some View {
        self
            .glassEffect(.regular.tint(Theme.accent.opacity(0.16)), in: shape)
            .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
            .shadow(color: Theme.accent.opacity(0.12), radius: 20, x: 0, y: 8)
    }

    func glass(cornerRadius: CGFloat = 22) -> some View {
        glass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Press micro-interaction shared by tappable controls — a quick springy
/// press-down scale, the standard feel for polished fintech CTAs.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(
                colors: [Theme.accent.opacity(0.34), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 360
            )
            RadialGradient(
                colors: [Theme.loss.opacity(0.16), .clear],
                center: .bottomLeading,
                startRadius: 28,
                endRadius: 420
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.52)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - **bold** / *italic* emphasis in spec copy

/// Renders the spec's markdown emphasis markers (the evidence citation uses
/// **bold** and *italic*); bold runs are lifted to cream against muted body text.
func emphasized(_ raw: String) -> AttributedString {
    var attributed = (try? AttributedString(
        markdown: raw,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
    )) ?? AttributedString(raw)
    // Collect ranges first — mutating while iterating `runs` invalidates them.
    let boldRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
        guard let intent = run.inlinePresentationIntent,
              intent.contains(.stronglyEmphasized) else { return nil }
        return run.range
    }
    for range in boldRanges {
        attributed[range].foregroundColor = Theme.cream
    }
    return attributed
}
