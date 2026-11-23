import SwiftUI

/// Animates a number from 0 to `to` over `duration` seconds with a strong
/// ease-out curve, rendered with thousands separators. Font/gradient styling
/// is applied by the parent (e.g. `.font(...)`, `.foregroundStyle(...)`).
/// By default the count starts immediately; with `startOnScrollVisible` it
/// waits until the text scrolls into view (≥60% visible) and runs once.
struct CountUpText: View {
    let to: Double
    var duration: Double = 2.4
    var delay: Double = 0
    var prefix: String = ""
    var decimals: Int = 0
    var startOnScrollVisible: Bool = false
    var onDone: (() -> Void)? = nil

    @State private var value: Double = 0
    @State private var started = false

    private var display: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        let body = f.string(from: NSNumber(value: value)) ?? String(value)
        return prefix + body
    }

    var body: some View {
        Text(display)
            .monospacedDigit()
            .task {
                guard !startOnScrollVisible else { return }
                await run()
            }
            .onScrollVisibilityChange(threshold: 0.6) { visible in
                guard startOnScrollVisible, visible else { return }
                Task { await run() }
            }
            .task {
                // Safety net: views inserted mid-screen (e.g. an expanding
                // panel) may not get a visibility callback — start anyway
                // after a beat. `started` makes this idempotent.
                guard startOnScrollVisible else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await run()
            }
    }

    private func run() async {
        guard !started else { return }
        started = true
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        let start = Date()
        while !Task.isCancelled {
            let progress = min(1, Date().timeIntervalSince(start) / duration)
            value = to * easeOut(progress)
            if progress >= 1 { break }
            try? await Task.sleep(nanoseconds: 16_000_000) // ~60fps
        }
        value = to
        onDone?()
    }

    /// Strong ease-out, approximating cubic-bezier(0.16, 1, 0.3, 1).
    private func easeOut(_ p: Double) -> Double {
        1 - pow(1 - p, 4)
    }
}
