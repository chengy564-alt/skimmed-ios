import SwiftUI

/// "Where it leaked" — a dark world map on Home where every country glows
/// amber by how much markup was lost there. Auto-frames the lit region,
/// tapping a lit country routes to its trip audit. Geometry comes from a
/// bundled Natural Earth extract (154KB, offline — no map service, no
/// network); city-states below the shape resolution (HK/SG/MO) render as
/// glow dots at fixed coordinates. Purely decorative color scaling — every
/// number shown is the same observed markup the rest of Home reports.
struct LeakMapCard: View {
    /// Markup lost per ISO country code (already aggregated by the caller).
    let lossByCountry: [String: Double]
    /// Blur the amounts (paywall's continue-with-limited state) — the glow
    /// stays, the numbers hide, matching every other loss display.
    let blurAmounts: Bool
    var onOpenCountry: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var totalLoss: Double { lossByCountry.values.reduce(0, +) }

    private var worst: (country: String, loss: Double)? {
        lossByCountry.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHERE IT LEAKED")
                .font(.app(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.muted)

            WorldLeakMap(
                lossByCountry: lossByCountry,
                animateGlow: !reduceMotion,
                onTapCountry: onOpenCountry
            )
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.97)

            if let worst {
                HStack(spacing: 6) {
                    Text(Derive.flag(worst.country))
                        .font(.system(size: 13))
                    Text("\(Derive.countryName(worst.country)) took the most")
                        .font(.app(11.5))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text("−\(Derive.fmtMoney(worst.loss))")
                        .font(.app(12, weight: .bold))
                        .foregroundStyle(Theme.loss)
                        .blur(radius: blurAmounts ? 6 : 0)
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .surfaceCard(cornerRadius: 20)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}

// MARK: - The map itself

private struct WorldLeakMap: View {
    let lossByCountry: [String: Double]
    let animateGlow: Bool
    var onTapCountry: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            Group {
                if animateGlow {
                    // Slow breathing on the glow layer — one shared phase, ~6s.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                        canvas(phase: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    canvas(phase: 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location, in: proxy.size)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    private func canvas(phase: TimeInterval) -> some View {
        Canvas { context, size in
            let geo = WorldGeometry.shared
            guard !geo.countries.isEmpty else { return }
            let lit = lossByCountry.filter { $0.value > 0 }
            let maxLoss = lit.values.max() ?? 1

            let viewport = Self.viewport(for: Set(lit.keys), geometry: geo)
            func project(_ lon: Double, _ lat: Double) -> CGPoint {
                let x = (lon - viewport.minX) / viewport.width * size.width
                let y = (viewport.maxY - lat) / viewport.height * size.height
                return CGPoint(x: x, y: y)
            }

            // Breathing multiplier for the glow (0.75...1.0).
            let breathe = animateGlow ? 0.875 + 0.125 * sin(phase * 2 * .pi / 6) : 1

            // Base landmass — barely-there fills so the world reads as context.
            for country in geo.countries where country.bbox.intersects(viewport.insetBy(dx: -viewport.width, dy: -viewport.height)) {
                let path = country.cgPath(project: project)
                context.fill(path, with: .color(Color.white.opacity(0.045)))
                context.stroke(path, with: .color(Color.white.opacity(0.07)), lineWidth: 0.5)
            }

            // Lit countries — blurred glow underneath, crisp amber fill on top.
            for country in geo.countries {
                guard let loss = lit[country.iso], loss > 0 else { continue }
                let intensity = sqrt(loss / maxLoss) // sqrt: small losses stay visible
                let path = country.cgPath(project: project)

                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 10))
                    layer.fill(path, with: .color(Theme.accent.opacity(0.55 * intensity * breathe)))
                }
                context.fill(path, with: .color(Theme.accent.opacity(0.18 + 0.5 * intensity)))
                context.stroke(path, with: .color(Theme.accent.opacity(0.35 + 0.45 * intensity)), lineWidth: 0.8)
            }

            // City-states below shape resolution — glowing dots.
            for (iso, loss) in lit {
                guard let center = WorldGeometry.cityStates[iso] else { continue }
                let intensity = sqrt(loss / maxLoss)
                let p = project(center.lon, center.lat)
                let r = 3 + 5 * intensity
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 8))
                    layer.fill(dot, with: .color(Theme.accent.opacity(0.7 * intensity * breathe)))
                }
                context.fill(dot, with: .color(Theme.accent.opacity(0.3 + 0.5 * intensity)))
            }
        }
    }

    /// Map the tap back through the same projection and open the nearest lit
    /// country (centroid distance — forgiving enough that glow dots and
    /// small countries stay easy to hit).
    private func handleTap(at location: CGPoint, in size: CGSize) {
        let geo = WorldGeometry.shared
        let lit = lossByCountry.filter { $0.value > 0 }
        guard !lit.isEmpty, size.width > 0, size.height > 0 else { return }
        let viewport = Self.viewport(for: Set(lit.keys), geometry: geo)
        var best: (iso: String, distance: Double)? = nil
        for (iso, _) in lit {
            let center: (lon: Double, lat: Double)
            if let cs = WorldGeometry.cityStates[iso] {
                center = cs
            } else if let c = geo.countries.first(where: { $0.iso == iso }) {
                center = (c.bbox.midX, c.bbox.midY)
            } else { continue }
            let fx = (center.lon - viewport.minX) / viewport.width
            let fy = (viewport.maxY - center.lat) / viewport.height
            let dx = fx - location.x / size.width
            let dy = fy - location.y / size.height
            let d = (dx * dx + dy * dy).squareRoot()
            if best == nil || d < best!.distance { best = (iso, d) }
        }
        // Within about a third of the card of the nearest lit centroid.
        if let best, best.distance < 0.35 {
            onTapCountry(best.iso)
        }
    }

    /// Framed viewport in lon/lat: the lit countries' union bbox, padded,
    /// aspect-corrected, minimum span enforced; world view when nothing lit.
    static func viewport(for litISOs: Set<String>, geometry: WorldGeometry) -> CGRect {
        var boxes: [CGRect] = geometry.countries
            .filter { litISOs.contains($0.iso) }
            .map(\.bbox)
        for iso in litISOs {
            if let cs = WorldGeometry.cityStates[iso] {
                boxes.append(CGRect(x: cs.lon - 2, y: cs.lat - 2, width: 4, height: 4))
            }
        }
        guard !boxes.isEmpty else { return CGRect(x: -170, y: -58, width: 340, height: 133) }
        var union = boxes[0]
        for b in boxes.dropFirst() { union = union.union(b) }
        // Pad 22% each side, enforce a minimum 40°×24° span so one small
        // country doesn't blow up to an unrecognisable close-up.
        var padded = union.insetBy(dx: -union.width * 0.22 - 4, dy: -union.height * 0.22 - 3)
        if padded.width < 40 { padded = padded.insetBy(dx: -(40 - padded.width) / 2, dy: 0) }
        if padded.height < 24 { padded = padded.insetBy(dx: 0, dy: -(24 - padded.height) / 2) }
        // Match the card's ~2.1 aspect (width/height in degrees ≈ 2× for
        // equirectangular at mid latitudes).
        let targetAspect = 2.4
        if padded.width / padded.height < targetAspect {
            let extra = padded.height * targetAspect - padded.width
            padded = padded.insetBy(dx: -extra / 2, dy: 0)
        } else {
            let extra = padded.width / targetAspect - padded.height
            padded = padded.insetBy(dx: 0, dy: -extra / 2)
        }
        return padded.intersection(CGRect(x: -180, y: -85, width: 360, height: 170))
    }
}

// MARK: - Geometry store (bundled Natural Earth extract)

/// Parses `world-countries.json` once: `[{i: "JP", t: "P"|"M", c: coords}]`.
final class WorldGeometry {
    struct Country {
        let iso: String
        /// Rings in lon/lat. Only outer rings — holes don't matter at this
        /// scale or styling.
        let rings: [[CGPoint]]
        let bbox: CGRect

        func cgPath(project: (Double, Double) -> CGPoint) -> Path {
            var path = Path()
            for ring in rings {
                guard let first = ring.first else { continue }
                path.move(to: project(Double(first.x), Double(first.y)))
                for pt in ring.dropFirst() {
                    path.addLine(to: project(Double(pt.x), Double(pt.y)))
                }
                path.closeSubpath()
            }
            return path
        }
    }

    static let shared = WorldGeometry()

    /// City-states absent from the 110m shapes — rendered as glow dots.
    static let cityStates: [String: (lon: Double, lat: Double)] = [
        "HK": (114.17, 22.30), "SG": (103.85, 1.35), "MO": (113.55, 22.20),
        "MT": (14.51, 35.90), "BH": (50.55, 26.05), "MV": (73.5, 4.2),
    ]

    let countries: [Country]

    private init() {
        guard let url = Bundle.main.url(forResource: "world-countries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            countries = []
            return
        }
        countries = raw.compactMap { entry in
            guard let iso = entry["i"] as? String,
                  let type = entry["t"] as? String,
                  let coords = entry["c"] else { return nil }
            var rings: [[CGPoint]] = []
            func ring(from any: Any) -> [CGPoint]? {
                guard let pts = any as? [[Any]] else { return nil }
                return pts.compactMap { pair in
                    guard pair.count >= 2,
                          let lon = (pair[0] as? NSNumber)?.doubleValue,
                          let lat = (pair[1] as? NSNumber)?.doubleValue else { return nil }
                    return CGPoint(x: lon, y: lat)
                }
            }
            if type == "P", let polygons = coords as? [Any] {
                // Polygon: [outerRing, hole...] — take the outer ring.
                if let outer = polygons.first, let r = ring(from: outer) { rings.append(r) }
            } else if type == "M", let multi = coords as? [Any] {
                for polygon in multi {
                    if let polyRings = polygon as? [Any], let outer = polyRings.first,
                       let r = ring(from: outer) {
                        rings.append(r)
                    }
                }
            }
            guard !rings.isEmpty else { return nil }
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for r in rings {
                for p in r {
                    minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                    minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
                }
            }
            return Country(iso: iso, rings: rings,
                           bbox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
    }
}
